unit dwsLinq;

interface
uses
   Classes,
   dwsComp, dwsCompiler, dwsLanguageExtension, dwsSymbols, dwsExprs, dwsUtils,
   dwsTokenizer, dwsErrors, dwsConstExprs, dwsRelExprs, dwsMethodExprs;

type
   TSqlFromExpr = class;
   TSqlList = class;
   TSqlIdentifier = class;

   TdwsLinqFactory = class(TdwsCustomLangageExtension)
   protected
      function CreateExtension : TdwsLanguageExtension; override;
   end;

   TdwsLinqExtension = class(TdwsLanguageExtension)
   private //utility functions
      class procedure Error(const compiler: IdwsCompiler; const msg: string); overload;
      class procedure Error(const compiler: IdwsCompiler; const msg: string; const args: array of const); overload;
      function TokenEquals(tok: TTokenizer; const value: string): boolean; inline;
   private
      FDatabaseSymbol: TClassSymbol;
      FDatasetSymbol: TClassSymbol;
      FRecursionDepth: integer;
      function EnsureDatabase(const compiler: IdwsCompiler): boolean;
      procedure ReadFromExprBody(const compiler: IdwsCompiler; tok: TTokenizer; from: TSqlFromExpr);
      function ReadFromExpression(const compiler: IdwsCompiler; tok : TTokenizer) : TSqlFromExpr;
      function DoReadFromExpr(const compiler: IdwsCompiler; tok: TTokenizer; db: TDataSymbol): TSqlFromExpr;
      procedure ReadWhereExprs(const compiler: IdwsCompiler; tok: TTokenizer; from: TSqlFromExpr);
      procedure ReadSelectExprs(const compiler: IdwsCompiler; tok: TTokenizer; from: TSqlFromExpr);
      function ReadWhereExpr(const compiler: IdwsCompiler; tok: TTokenizer): TRelOpExpr;
      function ReadSqlIdentifier(const compiler: IdwsCompiler;  tok: TTokenizer): TSqlIdentifier;
   public
      procedure ReadScript(compiler : TdwsCompiler; sourceFile : TSourceFile;
                           scriptType : TScriptSourceType); override;
      function ReadExpression(compiler: TdwsCompiler) : TTypedExpr; override;
   end;

   TSqlList = class(TObjectList<TTypedExpr>);

   TSqlFromExpr = class(TTypedExpr)
   private
      FTableName: string;
      FDBSymbol: TDataSymbol;
      FWhereList: TSqlList;
      FSelectList: TSqlList;
   private
      FSQL: string;
      FParams: TArrayConstantExpr;
      FMethod: TMethodExpr;
      function NewParam: string;
      procedure BuildSelectList(list: TStringList);
      procedure BuildQuery(compiler: TdwsCompiler);
      procedure Codegen(compiler: TdwsCompiler);
      procedure BuildWhereClause(compiler: TdwsCompiler; list: TStringList);
      procedure BuildWhereElement(expr: TTypedExpr; compiler: TdwsCompiler; list: TStringList);
      procedure BuildRelOpElement(expr: TRelOpExpr; compiler: TdwsCompiler;
        list: TStringList);
   public
      constructor Create(const tableName: string; const symbol: TDataSymbol);
      destructor Destroy; override;
      function Eval(exec : TdwsExecution) : Variant; override;
   end;

   TSqlIdentifier = class(TConstStringExpr)
   public
      constructor Create(const name: string; const compiler: IdwsCompiler);
   end;

implementation
uses
   SysUtils,
   dwsDatabaseLibModule, dwsUnitSymbols, dwsCoreExprs, dwsConvExprs;

{ TdwsLinqFactory }

function TdwsLinqFactory.CreateExtension: TdwsLanguageExtension;
begin
   Result:=TdwsLinqExtension.Create;
end;

{ TdwsLinqExtension }

class procedure TdwsLinqExtension.Error(const compiler: IdwsCompiler; const msg: string);
begin
   compiler.Msgs.AddCompilerError(compiler.Tokenizer.GetToken.FScriptPos, msg);
   Abort;
end;

class procedure TdwsLinqExtension.Error(const compiler: IdwsCompiler; const msg: string;
  const args: array of const);
begin
   error(compiler, format(msg, args));
end;

function TdwsLinqExtension.EnsureDatabase(const compiler: IdwsCompiler): boolean;
var
   db: TUnitMainSymbol;
begin
   result := true;
   if FDatabaseSymbol = nil then
   begin
      db := compiler.CurrentProg.UnitMains.Find('System.Data');
      if assigned(db) then
      begin
         FDatabaseSymbol := db.Table.FindTypeLocal('Database') as TClassSymbol;
         FDatasetSymbol := db.Table.FindTypeLocal('Dataset') as TClassSymbol;
      end;
      if FDatabaseSymbol = nil then
         Error(compiler, 'Database type not found in script');
      if FDatasetSymbol = nil then
         Error(compiler, 'Dataset type not found in script');
   end;
end;

function TdwsLinqExtension.ReadWhereExpr(const compiler: IdwsCompiler; tok: TTokenizer): TRelOpExpr;
var
   expr: TTypedExpr;
begin
   expr := compiler.readExpr;
   try
      if not(expr is TRelOpExpr) then
         Error(compiler, 'Comparison expected');
      result := TRelOpExpr(expr);
   except
      expr.Free;
      raise;
   end;
end;

procedure TdwsLinqExtension.ReadWhereExprs(const compiler: IdwsCompiler; tok: TTokenizer; from: TSqlFromExpr);
var
   expr: TTypedExpr;
begin
   from.FWhereList := TSqlList.Create;
   tok.KillToken;
   repeat
      expr := ReadWhereExpr(compiler, tok);
      try
         while tok.TestDelete(ttOr) do
            expr := TBoolOrExpr.Create(compiler.CurrentProg, expr, ReadWhereExpr(compiler, tok));
         from.FWhereList.Add(expr);
         expr := nil;
      except
         expr.Free;
         raise;
      end;
   until not tok.TestDelete(ttAND);
end;

procedure TdwsLinqExtension.ReadSelectExprs(const compiler: IdwsCompiler;
  tok: TTokenizer; from: TSqlFromExpr);
begin
   tok.KillToken;
   if tok.TestDelete(ttTIMES) then
      Exit;
   from.FSelectList := TSqlList.Create;
   repeat
      from.FSelectList.Add(ReadSqlIdentifier(compiler, tok));
   until not tok.TestDelete(ttCOMMA);
end;

procedure TdwsLinqExtension.ReadFromExprBody(const compiler: IdwsCompiler; tok: TTokenizer;
  from: TSqlFromExpr);
begin
//   if TokenEquals(tok, 'join') or TokenEquals(tok, 'left') or
//      TokenEquals(tok, 'right') or TokenEquals(tok, 'full') or TokenEquals('cross') then
//      ;
   if TokenEquals(tok, 'where') then
      ReadWhereExprs(compiler, tok, from);
//   if TokenEquals(tok, 'order') then
//      ;
//   if TokenEquals(tok, 'group') then
//      ;
   if TokenEquals(tok, 'select') then
      ReadSelectExprs(compiler, tok, from);
end;

function TdwsLinqExtension.DoReadFromExpr(const compiler: IdwsCompiler; tok: TTokenizer;
  db: TDataSymbol): TSqlFromExpr;
var
   token: TToken;
begin
   token := tok.GetToken;
   result := TSqlFromExpr.Create(token.AsString, db);
   try
      tok.KillToken;
      case tok.TestAny([ttSEMI, ttNAME]) of
         ttSemi: ;
         ttName: ReadFromExprBody(compiler, tok, result);
         else Error(compiler, 'Linq keyword expected');
      end;
      result.Typ := FDatasetSymbol;
   except
      result.Free;
      raise;
   end;
end;

function TdwsLinqExtension.ReadFromExpression(const compiler: IdwsCompiler; tok : TTokenizer): TSqlFromExpr;
var
   symbol: TSymbol;
begin
   result := nil;
   if not (tok.TestName and TokenEquals(tok, 'from')) then Exit;
   if not EnsureDatabase(compiler) then
      Exit;
   try
      inc(FRecursionDepth);
      try
         tok.KillToken;
         symbol := nil;
         if tok.TestName then
         begin
            symbol := compiler.CurrentProg.Table.FindSymbol(tok.GetToken.AsString, cvMagic);
            if not ((symbol is TDataSymbol) and (symbol.Typ.IsCompatible(FDatabaseSymbol))) then
               Error(compiler, '"%s" is not a database', [tok.GetToken.AsString]);
         end
         else Error(compiler, 'Identifier expected.');
         tok.KillToken;
         if not tok.TestDelete(ttDOT) then
            Error(compiler, '"." expected.');
         if not tok.Test(ttNAME) then
            Error(compiler, '"Identifier expected.');
         result := DoReadFromExpr(compiler, tok, TDataSymbol(symbol));
      except
         on EAbort do
            compiler.Msgs.AddCompilerStop(tok.GetToken.FScriptPos, 'Invalid LINQ expression');
      end;
   finally
      dec(FRecursionDepth);
   end;
end;

function TdwsLinqExtension.ReadSqlIdentifier(const compiler: IdwsCompiler; tok : TTokenizer): TSqlIdentifier;
begin
   if not tok.TestName then
      Error(compiler, 'Identifier expected.');
   result := TSqlIdentifier.Create(tok.GetToken.AsString, compiler);
   try
      tok.KillToken;
      if tok.TestDelete(ttDOT) then
      begin
         if not tok.TestName then
            Error(compiler, 'Identifier expected.');
         result.Value := format('%s.%s', [result.Value, tok.GetToken.AsString]);
         tok.KillToken;
      end;
   except
      result.Free;
      raise;
   end;
end;

function TdwsLinqExtension.ReadExpression(compiler: TdwsCompiler) : TTypedExpr;
var
   tok : TTokenizer;
begin
   tok:=compiler.Tokenizer;
   if FRecursionDepth = 0 then
   begin
      result := ReadFromExpression(compiler, tok);
      TSqlFromExpr(result).Codegen(compiler);
   end
   else result := ReadSqlIdentifier(compiler, tok);
end;

procedure TdwsLinqExtension.ReadScript(compiler: TdwsCompiler;
  sourceFile: TSourceFile; scriptType: TScriptSourceType);
begin
   inherited;
   FDatabaseSymbol := nil;
end;

function TdwsLinqExtension.TokenEquals(tok: TTokenizer; const value: string): boolean;
begin
   result := UnicodeSameText(tok.GetToken.AsString, value);
end;

{ TSqlFromExpr }

constructor TSqlFromExpr.Create(const tableName: string; const symbol: TDataSymbol);
begin
   inherited Create;
   FTableName := tableName;
   FDBSymbol := symbol;
end;

destructor TSqlFromExpr.Destroy;
begin
   FWhereList.Free;
   FSelectList.Free;
   inherited Destroy;
end;

procedure TSqlFromExpr.BuildSelectList(list: TStringList);
var
   i: integer;
   item: string;
begin
   list.Add('select');
   for i := 0 to FSelectList.Count - 1 do
   begin
      item := (FSelectList[i] as TSqlIdentifier).Value;
      if i < FSelectList.Count - 1 then
         item := item + ',';
      list.Add(item)
   end;
end;

function GetOp(expr: TRelOpExpr): string;
begin
   if expr.ClassType = TRelEqualVariantExpr then
      result := '='
   else if expr.ClassType = TRelNotEqualVariantExpr then
      result := '<>'
   else if expr.ClassType = TRelLessVariantExpr then
      result := '<'
   else if expr.ClassType = TRelLessEqualVariantExpr then
      result := '<='
   else if expr.ClassType = TRelGreaterVariantExpr then
      result := '>'
   else if expr.ClassType = TRelGreaterEqualVariantExpr then
      result := '>='
   else raise Exception.CreateFmt('Unknown op type: %s.', [expr.ClassName]);
end;

procedure TSqlFromExpr.BuildRelOpElement(expr: TRelOpExpr; compiler: TdwsCompiler; list: TStringList);
var
   l, r: string;
begin
   if expr.Left.ClassType = TSqlIdentifier then
      l := TSqlIdentifier(expr.Left).Value
   else begin
      l := NewParam;
      FParams.AddElementExpr(compiler.CurrentProg, expr.Left);
   end;

   if expr.right.ClassType = TSqlIdentifier then
      r := TSqlIdentifier(expr.right).Value
   else begin
      r := NewParam;
      FParams.AddElementExpr(compiler.CurrentProg, expr.right);
   end;

   list.Add(format('%s %s %s', [l, GetOp(expr), r]));
end;

procedure TSqlFromExpr.BuildWhereElement(expr: TTypedExpr; compiler: TdwsCompiler; list: TStringList);
begin
   if expr is TBooleanBinOpExpr then
   begin
      list.Add('(');
      BuildWhereElement(TBooleanBinOpExpr(expr).Left, compiler, list);
      if expr is TBoolAndExpr then
         list.Add(') and (')
      else if expr is TBoolOrExpr then
         list.Add(') or (')
      else TdwsLinqExtension.error(compiler, 'invalid binary operator');
      BuildWhereElement(TBooleanBinOpExpr(expr).Right, compiler, list);
      list.add(')');
   end
   else if expr is TRelOpExpr then
      BuildRelOpElement(TRelOpExpr(expr), compiler, list)
   else TdwsLinqExtension.error(compiler, 'invalid WHERE expression');
end;

procedure TSqlFromExpr.BuildWhereClause(compiler: TdwsCompiler; list: TStringList);
var
   i: integer;
   expr: TTypedExpr;
begin
   list.Add('where');
   for i := 0 to FWhereList.Count - 1 do
   begin
      expr := FWhereList[i];
      BuildWhereElement(expr, compiler, list);
      if i < FWhereList.Count - 1 then
         list.Add('and');
   end;
end;

procedure TSqlFromExpr.BuildQuery(compiler: TdwsCompiler);
var
   list: TStringList;
begin
   list := TStringList.Create;
   try
      if FSelectList = nil then
         list.Add('select *')
      else BuildSelectList(list);
      list.Add('from ' + FTableName);
      if assigned(FWhereList) then
         BuildWhereClause(compiler, list);
      FSql := list.Text;
   finally
      list.Free;
   end;
end;

procedure TSqlFromExpr.Codegen(compiler: TdwsCompiler);
var
   query: TMethodSymbol;
   prog: TdwsProgram;
   base: TVarExpr;
   pos: TScriptPos;
   arr: TTypedExpr;
begin
   query := (FDBSymbol.Typ as TClassSymbol).Members.FindSymbol('query', cvMagic) as TMethodSymbol;
   prog := compiler.CurrentProg;
   pos := compiler.Tokenizer.CurrentPos;
   base := TVarExpr.CreateTyped(prog, FDBSymbol);

   FParams := TArrayConstantExpr.Create(prog, pos);
   BuildQuery(compiler);

   FMethod := TMethodStaticExpr.Create(prog, pos, query, base);
   FMethod.AddArg(TConstStringExpr.Create(prog, nil, FSql));
   arr := TConvStaticArrayToDynamicExpr.Create(prog, FParams, TDynamicArraySymbol(query.Params.Symbols[1].Typ));
   FMethod.AddArg(arr);
   FMethod.Initialize(prog);
end;

function TSqlFromExpr.Eval(exec: TdwsExecution): Variant;
begin
   FMethod.EvalAsVariant(exec, result);
end;

function TSqlFromExpr.NewParam: string;
begin
   result := ':p' + IntToStr(FParams.Size + 1);
end;

{ TSqlIdentifier }

constructor TSqlIdentifier.Create(const name: string; const compiler: IdwsCompiler);
begin
   inherited Create(compiler.CurrentProg, compiler.CurrentProg.TypVariant, name);
end;

end.