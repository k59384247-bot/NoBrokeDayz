insert into public.job_categories (slug, label, enabled)
values
  ('errands', 'Errands', true),
  ('tutoring', 'Tutoring', true),
  ('design-creative', 'Design and creative work', true),
  ('writing-editing', 'Writing and editing', true),
  ('tech-help', 'Tech help', true),
  ('event-support', 'Event support', true),
  ('other-permitted-campus-services', 'Other permitted campus services', true);

-- Synthetic local-only domain; real institutional domains remain a launch gate.
insert into app_private.institutional_email_domains (domain, enabled, environment)
values ('school.test', true, 'synthetic_local')
on conflict (domain) do update set enabled = excluded.enabled, environment = excluded.environment;
