import { getWorkspace } from "@/lib/workspace";
import { athleteName, equipmentName, eventLabels, dateLabel, pageNumber } from "@/lib/presentation";
import { EmptyState, PageHeading, Panel, Pagination, WorkspaceRequired } from "@/components/ui/workspace-ui";

const pageSize = 50;
export default async function ActivityPage({ searchParams }: { searchParams: Promise<{ page?: string }> }) {
  const { supabase, organization } = await getWorkspace();
  const page = pageNumber((await searchParams).page);
  if (!organization) return <div className="content"><PageHeading eyebrow="HISTORY" title="Activity" description="Equipment updates and assignments." /><WorkspaceRequired /></div>;
  const { data: rows, count, error } = await supabase.from("equipment_events").select("id, event_type, created_at, equipment(name), athletes(first_name, last_name)", { count: "exact" }).eq("organization_id", organization.id).order("created_at", { ascending: false }).order("id").range((page - 1) * pageSize, page * pageSize - 1);
  if (error) throw error;
  return <div className="content"><PageHeading eyebrow="HISTORY" title="Activity" description="Equipment updates and assignments in your program." />
    <Panel title="Equipment history" description="Most recent first · dates in UTC" action={<span className="count-badge">{count ?? 0} events</span>}>
      {rows?.length ? <ul className="activity-list full-activity">{rows.map(event => <li key={event.id}><span className="activity-mark" aria-hidden="true">{event.event_type === "return" ? "↙" : "↗"}</span><div><strong>{eventLabels[event.event_type] ?? event.event_type} · {equipmentName(event.equipment)}</strong><p>{athleteName(event.athletes)} · <time dateTime={event.created_at}>{dateLabel(event.created_at)}</time></p></div></li>)}</ul> : <EmptyState title="No activity to show" description="Equipment updates and assignments will appear here when they are recorded." />}
      <Pagination page={page} count={count ?? 0} pageSize={pageSize} href="/dashboard/activity" />
    </Panel></div>;
}
