export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export function upstreamError(code: string, message: string): HttpError {
  return new HttpError(503, code, message);
}
