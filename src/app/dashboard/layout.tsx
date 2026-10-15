import { redirect } from "next/navigation";
import { DashboardShell } from "@/components/dashboard-shell";
import { createClient } from "@/lib/supabase/server";

export default async function DashboardLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();
  if (error || !data?.claims) redirect("/login");
  const email = typeof data.claims.email === "string" ? data.claims.email : "Team member";
  const { data: membership } = await supabase.from("organization_members").select("organizations(name)").order("created_at").limit(1).maybeSingle();
  const org = Array.isArray(membership?.organizations) ? membership.organizations[0] : membership?.organizations;
  return <DashboardShell email={email} organization={org?.name ?? null}>{children}</DashboardShell>;
}
