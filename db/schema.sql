-- Cafetería F10 · esquema de Supabase
-- Vive en el proyecto "torneo-f10" con el prefijo caf_ para no mezclarse con las tablas del torneo.
-- Acceso: solo las cuentas listadas en caf_acceso (no basta con estar autenticado).

-- ---------- acceso ----------
-- Sistema privado: solo entra el personal autorizado del Club F-10, no es un registro público.
--
-- Para autorizar a alguien NUEVO (que todavía no tiene cuenta):
--   insert into public.caf_correos_autorizados (email, nota) values ('correo@ejemplo.com', 'nombre de la persona');
--   Esa persona entra sola a la app, pulsa "Primera vez: activar mi acceso", pone su correo y
--   elige su propia contraseña — el disparador caf_alta_automatica_trigger le da acceso solo
--   porque su correo ya está en la lista. Si Supabase pide confirmar el correo, debe hacerlo
--   antes de poder entrar.
--
-- Para dar acceso a una cuenta que YA EXISTE (se registró antes de estar autorizada):
--   insert into public.caf_acceso (user_id) select id from auth.users where email = 'correo@ejemplo.com';
create table if not exists public.caf_acceso (
  user_id uuid primary key references auth.users(id) on delete cascade,
  creado  timestamptz not null default now()
);

-- Lista de correos autorizados a entrar. Nadie puede leerla ni escribirla desde la app (sin
-- políticas RLS): solo el dueño del proyecto la edita por SQL.
create table if not exists public.caf_correos_autorizados (
  email  text primary key,
  nota   text not null default '',
  creado timestamptz not null default now()
);
alter table public.caf_correos_autorizados enable row level security;

-- Cuando alguien crea una cuenta con un correo de la lista, se le da acceso automáticamente.
create or replace function public.caf_alta_automatica()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.caf_correos_autorizados where lower(email) = lower(new.email)) then
    insert into public.caf_acceso (user_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end;
$$;
revoke all on function public.caf_alta_automatica() from public, anon, authenticated;
revoke all on public.caf_correos_autorizados from anon, authenticated;

drop trigger if exists caf_alta_automatica_trigger on auth.users;
create trigger caf_alta_automatica_trigger
  after insert on auth.users
  for each row execute function public.caf_alta_automatica();

-- Autoservicio: cualquier persona ya autorizada puede administrar el acceso desde la
-- pestaña "Acceso" de la app, sin tocar SQL. Cada función comprueba primero que quien
-- llama ya esté en caf_acceso (si no, "No autorizado"); caf_quitar_autorizado además
-- no deja que alguien se quite su propio acceso por accidente.
create or replace function public.caf_listar_autorizados()
returns table(email text, nota text, creado timestamptz, activo boolean)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.caf_acceso where user_id = auth.uid()) then
    raise exception 'No autorizado';
  end if;
  return query
    select ca.email, ca.nota, ca.creado,
           exists (select 1 from auth.users u join public.caf_acceso a on a.user_id = u.id
                   where lower(u.email) = lower(ca.email)) as activo
    from public.caf_correos_autorizados ca order by ca.creado desc;
end;
$$;

create or replace function public.caf_autorizar_correo(p_email text, p_nota text default '')
returns void
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(btrim(p_email));
begin
  if not exists (select 1 from public.caf_acceso where user_id = auth.uid()) then
    raise exception 'No autorizado';
  end if;
  if v_email is null or v_email = '' or v_email not like '%@%' then
    raise exception 'Correo inválido';
  end if;
  insert into public.caf_correos_autorizados (email, nota) values (v_email, coalesce(btrim(p_nota), ''))
  on conflict (email) do update set nota = excluded.nota;
end;
$$;

create or replace function public.caf_quitar_autorizado(p_email text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(btrim(p_email));
begin
  if not exists (select 1 from public.caf_acceso where user_id = auth.uid()) then
    raise exception 'No autorizado';
  end if;
  if exists (select 1 from auth.users where id = auth.uid() and lower(email) = v_email) then
    raise exception 'No puedes quitar tu propio acceso desde aquí';
  end if;
  delete from public.caf_correos_autorizados where lower(email) = v_email;
  delete from public.caf_acceso where user_id in (select id from auth.users where lower(email) = v_email);
end;
$$;

revoke all on function public.caf_listar_autorizados() from public, anon;
revoke all on function public.caf_autorizar_correo(text, text) from public, anon;
revoke all on function public.caf_quitar_autorizado(text) from public, anon;
grant execute on function public.caf_listar_autorizados() to authenticated;
grant execute on function public.caf_autorizar_correo(text, text) to authenticated;
grant execute on function public.caf_quitar_autorizado(text) to authenticated;

-- ---------- tablas ----------
create table if not exists public.caf_productos (
  id                uuid primary key default gen_random_uuid(),
  nombre            text not null check (length(btrim(nombre)) > 0),
  categoria         text not null default '',
  unidad            text not null default 'unidades',
  cantidad_existente numeric not null default 0,
  precio            numeric not null default 0 check (precio >= 0),
  -- umbral para la etiqueta "stock bajo" en Productos; 0 = alerta desactivada para ese producto
  stock_minimo      numeric not null default 0 check (stock_minimo >= 0),
  creado            timestamptz not null default now()
);

create table if not exists public.caf_distribuidoras (
  id       uuid primary key default gen_random_uuid(),
  nombre   text not null check (length(btrim(nombre)) > 0),
  contacto text not null default '',
  activo   boolean not null default true,
  creado   timestamptz not null default now()
);

create table if not exists public.caf_pedidos (
  id               uuid primary key default gen_random_uuid(),
  producto_id      uuid references public.caf_productos(id) on delete set null,
  distribuidora_id uuid references public.caf_distribuidoras(id) on delete set null,
  cantidad         numeric not null check (cantidad > 0),
  estado           text not null default 'pendiente' check (estado in ('pendiente', 'recibido', 'cancelado')),
  historial        jsonb not null default '[]'::jsonb,
  creado           timestamptz not null default now()
);
create index if not exists caf_pedidos_producto_idx on public.caf_pedidos(producto_id);
create index if not exists caf_pedidos_distribuidora_idx on public.caf_pedidos(distribuidora_id);

create table if not exists public.caf_conteos (
  id          uuid primary key default gen_random_uuid(),
  fecha       date not null,
  -- si se borra el producto, el conteo se conserva (para no perder el historial de ventas)
  producto_id uuid references public.caf_productos(id) on delete set null,
  entrada     numeric not null default 0,
  salida      numeric not null default 0,
  precio      numeric not null default 0,
  vendido     numeric generated always as (entrada - salida) stored,
  dinero      numeric generated always as ((entrada - salida) * precio) stored,
  actualizado timestamptz not null default now(),
  unique (fecha, producto_id)
);
create index if not exists caf_conteos_producto_idx on public.caf_conteos(producto_id);

create table if not exists public.caf_canchas (
  id          uuid primary key default gen_random_uuid(),
  fecha       date not null unique,
  cant_baja   integer not null default 0 check (cant_baja >= 0),
  cant_alta   integer not null default 0 check (cant_alta >= 0),
  festivo     boolean not null default false,
  actualizado timestamptz not null default now()
);

-- ---------- seguridad (RLS) ----------
alter table public.caf_acceso        enable row level security;
alter table public.caf_productos     enable row level security;
alter table public.caf_distribuidoras enable row level security;
alter table public.caf_pedidos       enable row level security;
alter table public.caf_conteos       enable row level security;
alter table public.caf_canchas       enable row level security;

-- Cada cuenta solo puede ver si ella misma tiene acceso; el alta se hace desde el SQL del panel.
drop policy if exists caf_acceso_propio on public.caf_acceso;
create policy caf_acceso_propio on public.caf_acceso
  for select to authenticated using (user_id = (select auth.uid()));

do $$
declare t text;
begin
  foreach t in array array['caf_productos', 'caf_distribuidoras', 'caf_pedidos', 'caf_conteos', 'caf_canchas'] loop
    execute format('drop policy if exists %I on public.%I', t || '_miembros', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (exists (select 1 from public.caf_acceso a where a.user_id = (select auth.uid()))) with check (exists (select 1 from public.caf_acceso a where a.user_id = (select auth.uid())))',
      t || '_miembros', t);
  end loop;
end $$;

revoke all on public.caf_acceso, public.caf_productos, public.caf_distribuidoras,
              public.caf_pedidos, public.caf_conteos, public.caf_canchas from anon;

-- ---------- tiempo real ----------
alter publication supabase_realtime add table
  public.caf_productos, public.caf_distribuidoras, public.caf_pedidos, public.caf_conteos, public.caf_canchas;
