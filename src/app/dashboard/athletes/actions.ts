"use server";

import { redirect } from "next/navigation";
import { getWorkspace } from "@/lib/workspace";

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

  const { supabase, organization, role } = await getWorkspace();
  if (!organization) redirect("/dashboard");
  if (role !== "admin") redirect("/dashboard/athletes?status=forbidden");

  const { error } = await supabase.from("athletes").insert({
    organization_id: organization.id,
    first_name: firstName,
    last_name: lastName,
    team: team || null,
  });

  if (error) {
    redirect("/dashboard/athletes?status=error");
  }

  redirect("/dashboard/athletes?status=created");
}
