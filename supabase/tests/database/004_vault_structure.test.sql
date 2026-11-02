begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(25);

select has_table('public', 'vault_documents', 'vault_documents exists');
select has_table('public', 'swara_context_items', 'context_items exists');
select has_table('private', 'document_chunks', 'private.document_chunks exists');

select has_column('public', 'vault_documents', 'storage_bucket', 'vault_documents stores a bucket name');
select has_column('public', 'vault_documents', 'storage_path', 'vault_documents stores a storage path');
select has_column('private', 'document_chunks', 'embedding', 'document_chunks stores embeddings');
select has_column('private', 'document_chunks', 'embedding_model', 'document_chunks stores embedding model metadata');
select has_column('private', 'document_chunks', 'embedding_dimensions', 'document_chunks stores embedding dimension metadata');

select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.vault_documents'::regclass),
  'vault_documents has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.swara_context_items'::regclass),
  'context_items has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'private.document_chunks'::regclass),
  'document_chunks has RLS enabled'
);

select ok(
  exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.vault_documents'::regclass
      and conname = 'vault_documents_storage_bucket_check'
  ),
  'vault_documents constrains storage buckets'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.vault_documents'::regclass
      and conname = 'vault_documents_sha256_check'
  ),
  'vault_documents constrains SHA-256 values'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.swara_context_items'::regclass
      and conname = 'context_items_correction_reference_check'
  ),
  'context_items constrains correction references'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'private.document_chunks'::regclass
      and conname = 'document_chunks_embedding_dimension_match_check'
  ),
  'document_chunks constrains vector dimensions'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'document_chunks_document_owner_fkey'
  ),
  'document_chunks enforces document ownership'
);

select is(
  (
    select t.typname
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_type t on t.oid = a.atttypid
    where a.attrelid = 'private.document_chunks'::regclass
      and a.attname = 'embedding'
      and not a.attisdropped
  ),
  'vector',
  'embedding uses pgvector'
);

insert into auth.users (id)
values ('11111111-1111-4111-8111-111111111111');

select lives_ok(
  $$insert into public.vault_documents
      (id, user_id, filename, mime_type, size_bytes, sha256, storage_path, extraction_method)
    values
      ('33333333-3333-4333-8333-333333333333',
       '11111111-1111-4111-8111-111111111111',
       'note.txt', 'text/plain', 4,
       repeat('a', 64),
       '11111111-1111-4111-8111-111111111111/33333333-3333-4333-8333-333333333333/note.txt',
       'local')$$,
  'a valid Vault document satisfies its constraints'
);

select throws_ok(
  $$insert into public.vault_documents
      (user_id, filename, mime_type, size_bytes, sha256, storage_bucket, storage_path, extraction_method)
    values
      ('11111111-1111-4111-8111-111111111111', 'bad.txt', 'text/plain', 1,
       repeat('b', 64), 'not-a-vault-bucket', 'bad/path', 'local')$$,
  '23514'
);

select lives_ok(
  $$insert into private.document_chunks
      (user_id, document_id, chunk_index, content, token_count, embedding,
       embedding_model, embedding_dimensions)
    values
      ('11111111-1111-4111-8111-111111111111',
       '33333333-3333-4333-8333-333333333333', 0, 'hello', 1,
       '[0,0,0]'::extensions.vector, 'test-model', 3)$$,
  'a vector chunk with matching dimension metadata is accepted'
);

select is(
  (
    select extensions.vector_dims(embedding)
    from private.document_chunks
    where document_id = '33333333-3333-4333-8333-333333333333'
  ),
  3,
  'stored vector dimension matches the vector metadata'
);

select throws_ok(
  $$insert into private.document_chunks
      (user_id, document_id, chunk_index, content, token_count, embedding,
       embedding_model, embedding_dimensions)
    values
      ('11111111-1111-4111-8111-111111111111',
       '33333333-3333-4333-8333-333333333333', 1, 'wrong dimension', 2,
       '[0,0,0]'::extensions.vector, 'test-model', 2)$$,
  '23514'
);

select throws_ok(
  $$insert into private.document_chunks
      (user_id, document_id, chunk_index, content, token_count,
       embedding_model, embedding_dimensions)
    values
      ('11111111-1111-4111-8111-111111111111',
       '33333333-3333-4333-8333-333333333333', -1, 'bad index', 1,
       'test-model', 3)$$,
  '23514'
);

select throws_ok(
  $$insert into public.vault_documents
      (user_id, filename, mime_type, size_bytes, sha256, storage_path, extraction_method)
    values
      ('11111111-1111-4111-8111-111111111111', 'bad-hash.txt', 'text/plain', 1,
       repeat('G', 64), 'bad-hash.txt', 'local')$$,
  '23514'
);

select ok(
  exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.vault_documents'::regclass
      and conname = 'vault_documents_user_id_storage_location_key'
  ),
  'Vault document storage locations are unique per owner'
);

select * from finish();
rollback;
