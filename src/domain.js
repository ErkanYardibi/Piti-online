export const escapeHtml = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
export function localDate(date = new Date()) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
export function monthCells(cursor) {
  const start = new Date(cursor.getFullYear(), cursor.getMonth(), 1);
  start.setDate(start.getDate() - ((start.getDay() + 6) % 7));
  return Array.from({ length: 42 }, (_, i) => {
    const d = new Date(start);
    d.setDate(d.getDate() + i);
    return d;
  });
}
export function packageUsage(pkg, sessions) {
  return sessions.filter(
    (s) =>
      s.client_id === pkg.client_id &&
      s.counts_against_package &&
      ["completed", "no_show"].includes(s.status) &&
      localDate(new Date(s.starts_at)) >= pkg.start_date &&
      localDate(new Date(s.starts_at)) <= pkg.expiry_date,
  ).length;
}
export function isOverdue(session, now = Date.now()) {
  return (
    session.status === "planned" &&
    new Date(session.ends_at || session.starts_at).getTime() < now
  );
}
export function validateRange(start, end) {
  if (
    !start ||
    !end ||
    !Number.isFinite(new Date(start).getTime()) ||
    !Number.isFinite(new Date(end).getTime()) ||
    new Date(end) <= new Date(start)
  )
    throw new Error("Bitiş, başlangıçtan sonra olmalı.");
}
