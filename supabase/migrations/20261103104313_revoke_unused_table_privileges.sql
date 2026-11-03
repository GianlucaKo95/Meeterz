-- TRUNCATE umgeht RLS; REFERENCES und TRIGGER braucht die App nicht. Die REST-API nutzt nur SELECT/INSERT/UPDATE/DELETE.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke truncate, references, trigger on tables from anon, authenticated;
