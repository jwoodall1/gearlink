import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function EquipmentPage() {
  const supabase = await createClient();
  const { data: rows, error } = await supabase.from("equipment").select("id, name, category, size, color, condition, status, equipment_tags(uid, is_active)").order("created_at", { ascending: false });
  return <div className="content"><div className="page-heading"><div><p className="eyebrow">INVENTORY</p><h1>Equipment</h1><p className="muted">Keep track of every piece of team gear.</p></div><button className="button button-primary" disabled>＋ <span>Add equipment</span></button></div>
    <section className="panel list-panel"><div className="panel-heading"><div><h2>All equipment</h2><p>Equipment registered to your organization</p></div><span className="count-badge">{rows?.length ?? 0} items</span></div>
      {error ? <div className="inline-error">Unable to load equipment. Check your database migration and access permissions.</div> : rows?.length ? <div className="table-wrap"><table><thead><tr><th>Equipment</th><th>Category</th><th>Condition</th><th>Tag UID</th><th>Status</th></tr></thead><tbody>{rows.map((item) => <tr key={item.id}><td><strong>{item.name}</strong><small className="cell-sub">{[item.size, item.color].filter(Boolean).join(" · ") || "No size or color"}</small></td><td>{item.category}</td><td><span className="condition">{item.condition.replaceAll("_", " ")}</span></td><td className="uid-cell">{item.equipment_tags?.find((tag) => tag.is_active)?.uid ?? "Not tagged"}</td><td><span className={`pill ${item.status === "available" ? "available" : "checked"}`}>{item.status.replaceAll("_", " ")}</span></td></tr>)}</tbody></table></div> : <div className="empty-state"><span className="empty-icon">▧</span><strong>No equipment yet</strong><p>When equipment is registered in the iOS app or dashboard, it will appear here.</p><Link className="text-link" href="/dashboard">Back to overview <span>↗</span></Link></div>}
    </section></div>;
}
