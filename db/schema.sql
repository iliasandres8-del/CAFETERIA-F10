-- Cafetería F10 · esquema de Supabase
-- Vive en el proyecto "torneo-f10" con el prefijo caf_ para no mezclarse con las tablas del torneo.
-- Acceso: solo las cuentas listadas en caf_acceso (no basta con estar autenticado).

-- ---------- acceso ----------
-- Para dar acceso a una cuenta (después de que se registre en la app):
--   insert into public.caf_acceso (user_id) select id from auth.users where email = 'correo@ejemplo.com';
create table if not exists public.caf_acceso (
  user_id uuid primary key references auth.users(id) on delete cascade,
  creado  timestamptz not null default now()
);

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
