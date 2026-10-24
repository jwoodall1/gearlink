import Link from "next/link";
import type { ReactNode } from "react";
import { displayLabel } from "@/lib/presentation";

export function PageHeading({ eyebrow, title, description, action }: { eyebrow: string; title: string; description: string; action?: ReactNode }) {
  return <div className="page-heading"><div><p className="eyebrow">{eyebrow}</p><h1>{title}</h1><p className="muted">{description}</p></div>{action}</div>;
}
export function Panel({ title, description, action, children }: { title: string; description?: string; action?: ReactNode; children: ReactNode }) {
  return <section className="panel"><div className="panel-heading"><div><h2>{title}</h2>{description && <p>{description}</p>}</div>{action}</div>{children}</section>;
}
export function EmptyState({ title, description, action }: { title: string; description: string; action?: ReactNode }) {
  return <div className="empty-state"><span className="empty-icon" aria-hidden="true">◇</span><strong>{title}</strong><p>{description}</p>{action}</div>;
}
export function WorkspaceRequired() {
  return <EmptyState title="Set up your program first" description="Create an organization from Overview, or ask your administrator for access." action={<Link className="button button-secondary" href="/dashboard">Go to Overview</Link>} />;
}
export function StatusBadge({ value }: { value: string }) {
  const tone = value === "available" ? "available" : value === "checked_out" ? "checked" : value === "maintenance" || value === "needs_repair" ? "attention" : "neutral";
  return <span className={`pill ${tone}`}>{value === "checked_out" ? "Issued" : displayLabel(value)}</span>;
}
export function MetricCard({ label, value, detail, href }: { label: string; value: number; detail: string; href: string }) {
  return <Link className="stat-card metric-link" href={href}><span className="stat-top">{label}<span aria-hidden="true">↗</span></span><strong>{value.toLocaleString("en-US")}</strong><small>{detail}</small></Link>;
}
export function Pagination({ page, count, pageSize, href }: { page: number; count: number; pageSize: number; href: string }) {
  const pages = Math.max(1, Math.ceil(count / pageSize));
  const link = (target: number) => `${href}${href.includes("?") ? "&" : "?"}page=${target}`;
  return <nav className="pagination" aria-label="Pagination"><span>{count.toLocaleString("en-US")} total · Page {page} of {pages}</span><div>{page > 1 && <Link className="button button-secondary" href={link(page - 1)}>Previous</Link>}{page < pages && <Link className="button button-secondary" href={link(page + 1)}>Next</Link>}{page > pages && <Link className="button button-secondary" href={link(1)}>First page</Link>}</div></nav>;
}
