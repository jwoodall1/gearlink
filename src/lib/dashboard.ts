import { createClient } from "@/lib/supabase/server";

export async function getDashboardData() {
  const supabase = await createClient();
  const { data: memberships, error: membershipError } = await supabase
    .from("organization_members")
    .select("organization_id, role, organizations(id, name)")
    .order("created_at");

  if (membershipError) throw membershipError;
  const membership = memberships?.[0];
  const organization = Array.isArray(membership?.organizations)
    ? membership.organizations[0]
    : membership?.organizations;

  if (!membership || !organization) {
    return { organization: null, equipment: [], athletes: [], assignments: [], events: [] };
  }

  const orgId = membership.organization_id;
  const [equipment, athletes, assignments, events] = await Promise.all([
    supabase.from("equipment").select("id, name, category, size, condition, status", { count: "exact" }).eq("organization_id", orgId).order("created_at", { ascending: false }).limit(8),
    supabase.from("athletes").select("id, first_name, last_name, team, active").eq("organization_id", orgId).eq("active", true).order("last_name").limit(8),
    supabase.from("equipment_assignments").select("id, equipment_id, athlete_id, checked_out_at, equipment(name), athletes(first_name, last_name)", { count: "exact" }).eq("organization_id", orgId).is("returned_at", null).order("checked_out_at", { ascending: false }).limit(8),
    supabase.from("equipment_events").select("id, event_type, created_at, equipment(name), athletes(first_name, last_name)").eq("organization_id", orgId).order("created_at", { ascending: false }).limit(6),
  ]);
  const failed = [equipment, athletes, assignments, events].find((result) => result.error);
  if (failed?.error) throw failed.error;

  return {
    organization,
    equipment: equipment.data ?? [],
    equipmentCount: equipment.count ?? 0,
    assignmentCount: assignments.count ?? 0,
    athletes: athletes.data ?? [],
    assignments: assignments.data ?? [],
    events: events.data ?? [],
  };
}
