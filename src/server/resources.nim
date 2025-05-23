## MCP server resource utilities

import asyncdispatch, json, options, sequtils, os, streams, strutils, base64

proc createResourceInfo*(uri: string, name: string, description: string = "", mimeType: string = "", size: int = -1): JsonNode =
  result = %*{
    "uri": uri,
    "name": name
  }
  
  if description.len > 0:
    result["description"] = %description
    
  if mimeType.len > 0:
    result["mimeType"] = %mimeType
    
  if size >= 0:
    result["size"] = %size

proc createTextResourceContent*(uri: string, text: string, mimeType: string = "text/plain"): JsonNode =
  result = %*{
    "uri": uri,
    "mimeType": mimeType,
    "text": text
  }

proc createBinaryResourceContent*(uri: string, data: string, mimeType: string = "application/octet-stream"): JsonNode =
  result = %*{
    "uri": uri,
    "mimeType": mimeType,
    "blob": data
  }

proc createResourceTemplate*(uriTemplate: string, name: string, description: string = "", mimeType: string = "", arguments: seq[JsonNode] = @[]): JsonNode =
  result = %*{
    "uriTemplate": uriTemplate,
    "name": name
  }
  
  if description.len > 0:
    result["description"] = %description
    
  if mimeType.len > 0:
    result["mimeType"] = %mimeType
    
  if arguments.len > 0:
    result["arguments"] = %arguments

proc createTemplateArgument*(name: string, description: string = "", required: bool = false): JsonNode =
  result = %*{
    "name": name,
    "required": required
  }
  
  if description.len > 0:
    result["description"] = %description

proc detectMimeType*(path: string): string =
  let ext = path.splitFile.ext.toLowerAscii()
  
  case ext
  of ".txt":
    return "text/plain"
  of ".md":
    return "text/markdown"
  of ".html", ".htm":
    return "text/html"
  of ".css":
    return "text/css"
  of ".js":
    return "application/javascript"
  of ".json":
    return "application/json"
  of ".xml":
    return "application/xml"
  of ".pdf":
    return "application/pdf"
  of ".png":
    return "image/png"
  of ".jpg", ".jpeg":
    return "image/jpeg"
  of ".gif":
    return "image/gif"
  of ".svg":
    return "image/svg+xml"
  of ".mp3":
    return "audio/mpeg"
  of ".wav":
    return "audio/wav"
  of ".mp4":
    return "video/mp4"
  of ".webm":
    return "video/webm"
  of ".zip":
    return "application/zip"
  of ".tar":
    return "application/x-tar"
  of ".gz":
    return "application/gzip"
  of ".nim":
    return "text/x-nim"
  of ".py":
    return "text/x-python"
  of ".c":
    return "text/x-c"
  of ".cpp", ".cc", ".cxx":
    return "text/x-c++"
  of ".h", ".hpp", ".hxx":
    return "text/x-c-header"
  of ".rs":
    return "text/x-rust"
  of ".go":
    return "text/x-go"
  of ".java":
    return "text/x-java"
  of ".cs":
    return "text/x-csharp"
  of ".ts":
    return "text/x-typescript"
  of ".rb":
    return "text/x-ruby"
  of ".php":
    return "text/x-php"
  of ".sh":
    return "text/x-shellscript"
  of ".bat":
    return "text/x-bat"
  of ".ps1":
    return "text/x-powershell"
  of ".sql":
    return "text/x-sql"
  else:
    return "application/octet-stream"

proc isTextFile*(mimeType: string): bool =
  return mimeType.startsWith("text/") or
         mimeType == "application/json" or
         mimeType == "application/javascript" or
         mimeType == "application/xml"

proc readFileAsResource*(path: string): Future[JsonNode] {.async.} =
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
    
  let mimeType = detectMimeType(path)
  let uri = "file://" & path
  let name = path.extractFilename
  
  if isTextFile(mimeType):
    # Read as text
    let text = readFile(path)
    return createTextResourceContent(uri, text, mimeType)
  else:
    # Read as binary
    let data = readFile(path)
    let encoded = base64.encode(data)
    return createBinaryResourceContent(uri, encoded, mimeType)

proc listDirectoryAsResources*(path: string, pattern: string = "*"): Future[seq[JsonNode]] {.async.} =
  result = @[]
  
  if not dirExists(path):
    raise newException(IOError, "Directory not found: " & path)
    
  for kind, file in walkDir(path):
    let name = file.extractFilename
    
    # Skip hidden files
    if name.startsWith("."):
      continue
      
    # Apply pattern matching
    if pattern \!= "*" and not name.match(pattern):
      continue
    
    let uri = "file://" & file
    
    case kind:
    of pcFile:
      let mimeType = detectMimeType(file)
      let size = getFileSize(file)
      result.add(createResourceInfo(uri, name, "", mimeType, size.int))
    of pcDir:
      result.add(createResourceInfo(uri, name, "Directory", "inode/directory", -1))
    else:
      # Skip links and other special files
      discard
