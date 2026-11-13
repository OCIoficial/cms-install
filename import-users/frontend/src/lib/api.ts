// Llamadas al backend (import-users/server/app.py). Mismo origen: la cookie
// del panel de administración va sola.

export const FIELDS = [
  { key: "username", label: "Username", hint: "Required" },
  { key: "first_name", label: "First name", hint: "New users" },
  { key: "last_name", label: "Last name", hint: "New users" },
  { key: "password", label: "Password", hint: "New users" },
  { key: "email", label: "Email", hint: "Optional" },
  { key: "region", label: "Region", hint: "Code or city" },
] as const;

export type Field = (typeof FIELDS)[number]["key"];

export interface Contest {
  id: number;
  name: string;
  description: string;
}

export interface Team {
  code: string;
  name: string;
}

export interface Meta {
  admin: string;
  contests: Contest[];
  teams: Team[];
}

export interface RowResult {
  values: Partial<Record<Field, string>>;
  errors: Partial<Record<Field, string>>;
  user: "new" | "existing";
  participation: null | "new" | "team" | "same";
  team: string | null;
}

export interface Summary {
  rows: number;
  errors: number;
  users_created: number;
  participations_created: number;
  teams_changed: number;
  unchanged: number;
}

export interface CheckResponse {
  rows: RowResult[];
  summary: Summary;
}

export interface ImportResponse {
  summary: Summary;
  ranking_notified: boolean | null;
}

export interface Payload {
  contest_id: number | null;
  mapped: Field[];
  rows: Partial<Record<Field, string>>[];
}

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public body: Record<string, unknown>,
  ) {
    super(message);
  }
}

const BASE = "/import-users/api";

async function call<T>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(BASE + path, {
    method: body === undefined ? "GET" : "POST",
    credentials: "same-origin",
    headers:
      body === undefined
        ? {}
        : { "Content-Type": "application/json", "X-Requested-With": "cms-import-users" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let data: Record<string, unknown>;
  try {
    data = await response.json();
  } catch {
    throw new ApiError(`Unexpected response from the server (${response.status}).`, response.status, {});
  }
  if (!response.ok) {
    throw new ApiError(String(data.error ?? response.statusText), response.status, data);
  }
  return data as T;
}

export const getMeta = () => call<Meta>("/meta");
export const preview = (p: Payload) => call<CheckResponse>("/preview", p);
export const runImport = (p: Payload) => call<ImportResponse>("/import", p);
