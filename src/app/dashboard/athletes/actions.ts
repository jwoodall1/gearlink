"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function createAthlete(formData: FormData) {
  const firstName = String(formData.get("first_name") ?? "").trim();
  const lastName = String(formData.get("last_name") ?? "").trim();
  const team = String(formData.get("team") ?? "").trim();

  if (firstName.length < 1 || firstName.length > 80 || lastName.length < 1 || lastName.length > 80) {
    redirect("/dashboard/athletes?status=invalid");
  }

  if (team.length > 120) {
    redirect("/dashboard/athletes?status=invalid");
  }

  const supabase = await createClient();
  const { data: membership, error: membershipError } = await supabase
    .from("organization_members")
    .select("organization_id")
    .order("created_at")
    .limit(1)
    .maybeSingle();

  if (membershipError || !membership) {
    redirect("/dashboard/athletes?status=workspace");
  }

  const { error } = await supabase.from("athletes").insert({
    organization_id: membership.organization_id,
    first_name: firstName,
    last_name: lastName,
    team: team || null,
  });

  if (error) {
    redirect("/dashboard/athletes?status=error");
  }

  redirect("/dashboard/athletes?status=created");
}
