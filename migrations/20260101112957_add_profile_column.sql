-- +migrate up
ALTER TABLE test_users ADD COLUMN profile_data JSONB;

-- +migrate down
ALTER TABLE test_users DROP COLUMN profile_data;
