import Link from "next/link";
import { getWorkspace } from "@/lib/workspace";
import { pageNumber, displayLabel } from "@/lib/presentation";
import { EmptyState, PageHeading, Panel, Pagination, StatusBadge, WorkspaceRequired } from "@/components/ui/workspace-ui";

const pageSize = 50;
export default async function EquipmentPage({ searchParams }: { searchParams: Promise<{ page?: string; status?: string; attention?: string; item?: string }> }) {
  const params = await searchParams;
  const { supabase, organization } = await getWorkspace();
  const page = pageNumber(params.page);
  const status = ["available", "checked_out", "maintenance", "retired"].includes(params.status ?? "") ? params.status : undefined;
  const attention = params.attention === "true";
  const item = params.item && /^[0-9a-f-]{36}$/i.test(params.item) ? params.item : undefined;
  if (!organization) return <div className="content"><PageHeading eyebrow="INVENTORY" title="Equipment" description="Your program's equipment records." /><WorkspaceRequired /></div>;
  let query = supabase.from("equipment").select("id, name, category, size, color, condition, status, equipment_tags(uid, is_active)", { count: "exact" }).eq("organization_id", organization.id);
  if (status) query = query.eq("status", status);
  if (attention) query = query.neq("status", "retired").or("status.eq.maintenance,condition.eq.needs_repair");
  if (item) query = query.eq("id", item);
  const { data: rows, count, error } = await query.order("created_at", { ascending: false }).order("id").range((page - 1) * pageSize, page * pageSize - 1);
  if (error) throw error;
  const filters = new URLSearchParams();
  if (status) filters.set("status", status);
  if (attention) filters.set("attention", "true");
  if (item) filters.set("item", item);
  const href = `/dashboard/equipment${filters.size ? `?${filters}` : ""}`;
  return <div className="content"><PageHeading eyebrow="INVENTORY" title="Equipment" description="Review your program's gear, condition, and availability." />
    <nav className="filter-links" aria-label="Inventory views"><Link href="/dashboard/equipment" aria-current={!status && !attention && !item ? "page" : undefined}>All equipment</Link><Link href="/dashboard/equipment?status=available" aria-current={status === "available" ? "page" : undefined}>Available</Link><Link href="/dashboard/equipment?status=checked_out" aria-current={status === "checked_out" ? "page" : undefined}>Issued</Link><Link href="/dashboard/equipment?attention=true" aria-current={attention ? "page" : undefined}>Needs attention</Link></nav>
    <Panel title={item ? "Selected equipment" : attention ? "Needs attention" : status ? displayLabel(status === "checked_out" ? "Issued" : status) : "All equipment"} description="Records in your current organization" action={<span className="count-badge">{count ?? 0} items</span>}>
      {rows?.length ? <div className="table-wrap" tabIndex={0} role="region" aria-label="Equipment inventory"><table><thead><tr><th scope="col">Equipment</th><th scope="col">Category</th><th scope="col">Condition</th><th scope="col">Tag UID</th><th scope="col">Status</th></tr></thead><tbody>{rows.map(item => <tr key={item.id}><td><strong>{item.name}</strong><small className="cell-sub">{[item.size, item.color].filter(Boolean).join(" · ") || "No size or color recorded"}</small></td><td>{item.category}</td><td><span className="condition">{displayLabel(item.condition)}</span></td><td className="uid-cell">{item.equipment_tags?.find(tag => tag.is_active)?.uid ?? "Not tagged"}</td><td><StatusBadge value={item.status} /></td></tr>)}</tbody></table></div> : <EmptyState title={status || attention || item || page > 1 ? "No equipment in this view" : "No equipment records yet"} description={status || attention || item || page > 1 ? "Return to all equipment to see the rest of your inventory." : "Registered equipment will appear here. You can prepare your athlete roster while inventory setup is being added."} action={<Link className="button button-secondary" href={status || attention || item || page > 1 ? "/dashboard/equipment" : "/dashboard/athletes"}>{status || attention || item || page > 1 ? "All equipment" : "View roster"}</Link>} />}
      <Pagination page={page} count={count ?? 0} pageSize={pageSize} href={href} />
    </Panel></div>;
}
