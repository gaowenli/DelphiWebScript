// dwsWebServerHelpers
{: egg<p>

   Helper class and utilities for web servers

   <b>Historique : </b><font size=-1><ul>
      <li>31/12/12 - egg - Creation
   </ul></font>
}
unit dwsWebServerHelpers;

interface

uses
   Windows, Classes, SysUtils,
   dwsUtils;

type
   TDirectoryIndexInfo = class(TRefCountedObject)
      private
         FIndexFileName : String;

      public
         property IndexFileName : String read FIndexFileName write FIndexFileName;
   end;

   TDirectoryIndexCache = class
      private
         FLock : TFixedCriticalSection;
         FHash : TSimpleNameObjectHash<TDirectoryIndexInfo>;
         FIndexFileNames : TStrings;

      protected
         function CreateIndexInfo(const directory : String) : TDirectoryIndexInfo;

      public
         constructor Create;
         destructor Destroy; override;

         function IndexFileForDirectory(var path : String) : Boolean;

         procedure Flush;

         property IndexFileNames : TStrings read FIndexFileNames;
   end;

// Decodes an http request URL and splits path & params
// Skips initial '/'
// Normalizes '/' to '\' for the pathInfo
procedure HttpRequestUrlDecode(const s : RawByteString; var pathInfo, params : String);

const
   cHTMTL_UTF8_CONTENT_TYPE = 'text/html; charset=utf-8';

// ------------------------------------------------------------------
// ------------------------------------------------------------------
// ------------------------------------------------------------------
implementation
// ------------------------------------------------------------------
// ------------------------------------------------------------------
// ------------------------------------------------------------------

procedure HttpRequestUrlDecode(const s : RawByteString; var pathInfo, params : String);
var
   n, c : Integer;
   decodedBuffer : UTF8String;
   pIn : PAnsiChar;
   pOut : PAnsiChar;
   paramsOffset : PAnsiChar;
begin
   n:=Length(s);
   if n=0 then begin
      pathInfo:='';
      params:='';
      Exit;
   end;
   SetLength(decodedBuffer, n);

   c:=0; // workaround for spurious compiler warning
   paramsOffset:=nil;
   pIn:=Pointer(s);
   if pIn^='/' then
      Inc(pIn);
   pOut:=Pointer(decodedBuffer);
   while True do begin
      case pIn^ of
         #0 : break;
         '%' : begin
            Inc(pIn);
            case pIn^ of
               '0'..'9' : c:=Ord(pIn^)-Ord('0');
               'a'..'f' : c:=Ord(pIn^)+(10-Ord('a'));
               'A'..'F' : c:=Ord(pIn^)+(10-Ord('A'));
            else
               break;  // invalid url
            end;
            Inc(pIn);
            case pIn^ of
               '0'..'9' : c:=(c shl 4)+Ord(pIn^)-Ord('0');
               'a'..'f' : c:=(c shl 4)+Ord(pIn^)+(10-Ord('a'));
               'A'..'F' : c:=(c shl 4)+Ord(pIn^)+(10-Ord('A'));
            else
               break;  // invalid url
            end;
            pOut^:=AnsiChar(c);
         end;
         '+' : pOut^:=' ';
         '?' : begin
            pOut^:='?';
            if paramsOffset=nil then
               paramsOffset:=pOut;
         end;
         '/' : begin
            if paramsOffset=nil then
               pOut^:='\'
            else pOut^:='/';
         end;
      else
         pOut^:=pIn^;
      end;
      Inc(pIn);
      Inc(pOut);
   end;

   if paramsOffset=nil then begin

      params:='';
      n:=UInt64(pOut)-UInt64(Pointer(decodedBuffer));
      SetLength(pathInfo, n);
      n:=MultiByteToWideChar(CP_UTF8, 0, Pointer(decodedBuffer), n, Pointer(pathInfo), n);
      SetLength(pathInfo, n);

   end else begin

      n:=UInt64(paramsOffset)-UInt64(Pointer(decodedBuffer));
      SetLength(pathInfo, n);
      n:=MultiByteToWideChar(CP_UTF8, 0, Pointer(decodedBuffer), n, Pointer(pathInfo), n);
      SetLength(pathInfo, n);

      n:=UInt64(pOut)-UInt64(paramsOffset);
      SetLength(params, n);
      n:=MultiByteToWideChar(CP_UTF8, 0, Pointer(paramsOffset), n, Pointer(params), n);
      SetLength(params, n);

   end;
end;

// ------------------
// ------------------ TDirectoryIndexCache ------------------
// ------------------

// Create
//
constructor TDirectoryIndexCache.Create;
begin
   inherited;
   FLock:=TFixedCriticalSection.Create;
   FHash:=TSimpleNameObjectHash<TDirectoryIndexInfo>.Create;
   FIndexFileNames:=TStringList.Create;
end;

// Destroy
//
destructor TDirectoryIndexCache.Destroy;
begin
   inherited;
   FHash.Free;
   FLock.Free;
end;

// IndexFileForDirectory
//
function TDirectoryIndexCache.IndexFileForDirectory(var path : String) : Boolean;
var
   indexInfo : TDirectoryIndexInfo;
begin
   if not StrEndsWith(path, PathDelim) then
      path:=path+PathDelim;

   FLock.Enter;
   try
      indexInfo:=FHash.Objects[path];
      if indexInfo=nil then begin
         indexInfo:=CreateIndexInfo(path);
         FHash.Objects[path]:=indexInfo;
      end;
      if indexInfo.IndexFileName<>'' then begin
         path:=indexInfo.IndexFileName;
         Result:=True;
      end else Result:=False;
   finally
      FLock.Leave;
   end;
end;

// Flush
//
procedure TDirectoryIndexCache.Flush;
begin
   FLock.Enter;
   try
      FHash.Free;
      FHash:=TSimpleNameObjectHash<TDirectoryIndexInfo>.Create;
   finally
      FLock.Leave;
   end;
end;

// CreateIndexInfo
//
function TDirectoryIndexCache.CreateIndexInfo(const directory : String) : TDirectoryIndexInfo;
var
   i : Integer;
   path, fileName : String;
begin
   Result:=TDirectoryIndexInfo.Create;

   path:=IncludeTrailingPathDelimiter(directory);

   for i:=0 to IndexFileNames.Count-1 do begin
      fileName:=path+IndexFileNames[i];
      if FileExists(fileName) then begin
         Result.IndexFileName:=fileName;
         Break;
      end;
   end;
end;

end.
