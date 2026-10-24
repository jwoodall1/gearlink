import { getWorkspace } from "@/lib/workspace";

export async function getDashboardData() {
  const { supabase, organization } = await getWorkspace();
  if (!organization) return {
    organization, equipmentCount: 0, availableCount: 0, assignmentCount: 0,
    athleteCount: 0, attentionCount: 0, assignments: [], events: [], attention: [],
  };
  const orgId = organization.id;
  const [equipment, available, athletes, assignments, events, attention] = await Promise.all([
    supabase.from("equipment").select("id", { count: "exact", head: true }).eq("organization_id", orgId),
    supabase.from("equipment").select("id", { count: "exact", head: true }).eq("organization_id", orgId).eq("status", "available"),
    supabase.from("athletes").select("id", { count: "exact", head: true }).eq("organization_id", orgId).eq("active", true),
    supabase.from("equipment_assignments").select("id, equipment_id, athlete_id, checked_out_at, equipment(name), athletes(first_name, last_name)", { count: "exact" }).eq("organization_id", orgId).is("returned_at", null).order("checked_out_at", { ascending: false }).order("id").limit(8),
    supabase.from("equipment_events").select("id, event_type, created_at, equipment(name), athletes(first_name, last_name)").eq("organization_id", orgId).order("created_at", { ascending: false }).order("id").limit(6),
    supabase.from("equipment").select("id, name, status, condition", { count: "exact" }).eq("organization_id", orgId).neq("status", "retired").or("status.eq.maintenance,condition.eq.needs_repair").order("updated_at", { ascending: false }).order("id").limit(4),
  ]);
  const failed = [equipment, available, athletes, assignments, events, attention].find((result) => result.error);
  if (failed?.error) throw failed.error;
  return {
    organization, equipmentCount: equipment.count ?? 0, availableCount: available.count ?? 0,
    assignmentCount: assignments.count ?? 0, athleteCount: athletes.count ?? 0,
    attentionCount: attention.count ?? 0, attention: attention.data ?? [],
    assignments: assignments.data ?? [], events: events.data ?? [],
  };
}
