// One error body for every API response.
export interface ErrorBody {
  error: {
    code: string;
    message: string;
  };
}

export function toErrorBody(code: string, message: string): ErrorBody {
  return { error: { code, message } };
}

export const UNKNOWN_ERROR = 'unknown_error';
