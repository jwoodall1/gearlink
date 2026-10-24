import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { relatedRow } from "@/lib/presentation";

// React cache is scoped to this server request, never shared between accounts.
export const getWorkspace = cache(async () => {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();
  if (error || !data?.claims?.sub) redirect("/login");
  const { data: membership, error: membershipError } = await supabase
    .from("organization_members")
    .select("organization_id, role, organizations(id, name)")
    .eq("user_id", data.claims.sub)
    .order("created_at").order("organization_id").limit(1).maybeSingle();
  if (membershipError) throw membershipError;
  const organization = relatedRow<{ id: string; name: string }>(membership?.organizations);
  if (membership && !organization) throw new Error("Workspace could not be loaded.");
  return {
    supabase, organization,
    role: membership?.role as "admin" | "coach" | undefined,
    email: typeof data.claims.email === "string" ? data.claims.email : "Team member",
  };
});
