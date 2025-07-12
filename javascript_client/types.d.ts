export type TextEncodingTypes = "text/plain" | "text/html" | "text/css" | "text/javascript" | "text/csv"
export type Header = {
  route: string
  requestHeaders: Record<string, string>
  requestType: "GET" | "POST" | "PUT" | "DELETE"
  contentType: TextEncodingTypes | "application/json" | "multipart/form-data"
}

export type MultipartBody = {
  textContent: Record<string, any>
  files: Blob[]
}

export type Body = string | Record<string, any> | MultipartBody

export type FetchMockParams = {
  method?: string,
  headers?: Record<string, string>,
  body?: any,
}
