begin;

create extension if not exists pgcrypto;

-- Company system settings (independent of legacy tables)
create table if not exists public.mk_settings (
  id boolean primary key default true,
  company_name text not null default 'MK Abuzahra Global Ventures Ltd',
  logo_url text,
  primary_color text not null default '#123b2a',
  secondary_color text not null default '#c9a227',
  mode text not null default 'light',
  commission_rate numeric(5,2) not null default 10 check (commission_rate between 0 and 100),
  claim_validity_hours integer not null default 48 check (claim_validity_hours between 1 and 720),
  allow_partial_redeem boolean not null default false,
  announcement text,
  advertiser_features jsonb not null default '{"sales":true,"commissions":true,"profile":true}'::jsonb,
  advertiser_feature_order jsonb not null default '["sales","commissions","profile"]'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.mk_settings(id) values(true) on conflict(id) do nothing;

create table if not exists public.mk_categories (
  id uuid primary key default gen_random_uuid(), name text not null unique, active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.mk_products (
  id uuid primary key default gen_random_uuid(), category_id uuid references public.mk_categories(id) on delete set null,
  name text not null, sku text unique, default_price numeric(14,2) not null default 0 check(default_price>=0),
  active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.mk_advertiser_details (
  id uuid primary key references public.profiles(id) on delete cascade,
  advertiser_code text unique,
  phone text not null, address text not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.mk_sales (
  id uuid primary key default gen_random_uuid(),
  sale_id text unique not null,
  advertiser_id uuid not null references public.profiles(id),
  customer_name text not null, customer_phone text not null, customer_location text not null,
  product_id uuid not null references public.mk_products(id), product_name text not null,
  quantity integer not null check(quantity>0), unit_price numeric(14,2) not null check(unit_price>=0),
  total_amount numeric(14,2) generated always as (quantity*unit_price) stored,
  payment_status text not null default 'UNPAID' check(payment_status in ('UNPAID','PARTIAL','PAID')),
  amount_paid numeric(14,2) not null default 0 check(amount_paid>=0),
  expected_collection_date date not null, status text not null default 'claimed' check(status in ('claimed','verified','redeemed','cancelled','expired','void')),
  created_at timestamptz not null default now(), verified_at timestamptz, redeemed_at timestamptz, verified_by uuid references public.profiles(id), redeemed_by uuid references public.profiles(id)
);
create sequence if not exists public.mk_sale_seq;
create sequence if not exists public.mk_advertiser_seq;

create table if not exists public.mk_authenticators (
  id uuid primary key default gen_random_uuid(), sale_uuid uuid unique not null references public.mk_sales(id) on delete cascade,
  code_hash text unique not null, expires_at timestamptz not null, used_at timestamptz, created_at timestamptz not null default now()
);

create table if not exists public.mk_commissions (
  id uuid primary key default gen_random_uuid(), sale_uuid uuid unique not null references public.mk_sales(id) on delete cascade,
  advertiser_id uuid not null references public.profiles(id), rate numeric(5,2) not null default 0,
  amount numeric(14,2) not null default 0, status text not null default 'PENDING' check(status in ('PENDING','ELIGIBLE','PAID')),
  eligible_at timestamptz, paid_at timestamptz, payment_reference text, notes text, updated_at timestamptz not null default now()
);

create table if not exists public.mk_audit_logs (
  id bigint generated always as identity primary key, actor_id uuid references public.profiles(id), action text not null,
  entity_type text, entity_id text, metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);

-- Safe helpers using the real profiles.status column.
create or replace function public.mk_is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles where id=auth.uid() and status='active' and role in ('super_admin','admin','staff'));
$$;
create or replace function public.mk_is_super_admin() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles where id=auth.uid() and status='active' and role='super_admin');
$$;

-- Complete registration after email confirmation/login. Uses auth metadata, so no service key is needed.
create or replace function public.mk_complete_registration() returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); meta jsonb:=coalesce((select raw_user_meta_data from auth.users where id=uid),'{}'); r public.profiles%rowtype;
begin
 if uid is null then raise exception 'Not signed in'; end if;
 if not exists(select 1 from public.profiles where id=uid) then
   insert into public.profiles(id,full_name,role,status) values(uid,coalesce(meta->>'full_name','Advertiser'),'advertiser','pending') returning * into r;
 else select * into r from public.profiles where id=uid; end if;
 insert into public.mk_advertiser_details(id,advertiser_code,phone,address) values(uid,'ADV-'||lpad(nextval('public.mk_advertiser_seq')::text,3,'0'),coalesce(meta->>'phone',''),coalesce(meta->>'address',''))
 on conflict(id) do update set phone=excluded.phone,address=excluded.address,updated_at=now();
 return jsonb_build_object('id',uid,'status',r.status);
end; $$;
grant execute on function public.mk_complete_registration() to authenticated;

create or replace function public.mk_register_profile(p_full_name text,p_phone text,p_address text) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); r public.profiles%rowtype;
begin
 if uid is null then raise exception 'Not signed in'; end if;
 insert into public.profiles(id,full_name,role,status) values(uid,trim(p_full_name),'advertiser','pending')
 on conflict(id) do update set full_name=excluded.full_name,role='advertiser',status=case when public.profiles.status='active' then 'active' else 'pending' end,updated_at=now()
 returning * into r;
 insert into public.mk_advertiser_details(id,advertiser_code,phone,address) values(uid,'ADV-'||lpad(nextval('public.mk_advertiser_seq')::text,3,'0'),trim(p_phone),trim(p_address)) on conflict(id) do update set phone=excluded.phone,address=excluded.address,updated_at=now();
 return jsonb_build_object('status',r.status);
end; $$;
grant execute on function public.mk_register_profile(text,text,text) to authenticated;

create or replace function public.mk_set_advertiser_status(p_id uuid,p_status text,p_note text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare s text:=lower(trim(p_status)); r public.profiles%rowtype;
begin
 if not public.mk_is_super_admin() then raise exception 'Only Super Admin can manage advertisers'; end if;
 if s not in ('pending','approved','active','rejected','suspended') then raise exception 'Invalid status'; end if;
 update public.profiles set status=case when s in ('approved','active') then 'active' else s end, approval_note=coalesce(nullif(trim(p_note),''),approval_note), approved_at=case when s in ('approved','active') then now() else approved_at end, approved_by=case when s in ('approved','active') then auth.uid() else approved_by end, updated_at=now() where id=p_id and role='advertiser' returning * into r;
 if not found then raise exception 'Advertiser not found'; end if;
 insert into public.mk_audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'ADVERTISER_STATUS','advertiser',p_id::text,jsonb_build_object('status',r.status,'note',p_note));
 return jsonb_build_object('id',r.id,'status',r.status);
end; $$;
grant execute on function public.mk_set_advertiser_status(uuid,text,text) to authenticated;

create or replace function public.mk_create_sale_claim(p_advertiser_id uuid,p_customer_name text,p_customer_phone text,p_product_id uuid,p_quantity integer,p_unit_price numeric,p_customer_location text,p_payment_status text,p_amount_paid numeric,p_expected_collection_date date) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); aid uuid:=coalesce(p_advertiser_id,uid); pr public.mk_products%rowtype; s public.mk_sales%rowtype; code text; sid text; rate numeric; hours integer; exp timestamptz;
begin
 if not public.mk_is_admin() and not (uid=aid and exists(select 1 from public.profiles where id=uid and role='advertiser' and status='active')) then raise exception 'Not authorized'; end if;
 if not exists(select 1 from public.profiles where id=aid and role='advertiser' and status='active') then raise exception 'Advertiser is not active'; end if;
 select * into pr from public.mk_products where id=p_product_id and active=true; if not found then raise exception 'Product not found or inactive'; end if;
 if p_quantity<1 or p_unit_price<0 then raise exception 'Invalid quantity or price'; end if;
 if p_payment_status not in ('UNPAID','PARTIAL','PAID') then raise exception 'Invalid payment status'; end if;
 if p_amount_paid<0 or p_amount_paid>(p_quantity*p_unit_price) then raise exception 'Invalid amount paid'; end if;
 if p_payment_status='PAID' and p_amount_paid < p_quantity*p_unit_price then raise exception 'Paid status requires full payment'; end if;
 if p_payment_status='UNPAID' and p_amount_paid<>0 then raise exception 'Unpaid status cannot have amount paid'; end if;
 select commission_rate,claim_validity_hours into rate,hours from public.mk_settings where id=true;
 sid:='SALE-'||to_char(now(),'YYYY')||'-'||lpad(nextval('public.mk_sale_seq')::text,5,'0');
 insert into public.mk_sales(sale_id,advertiser_id,customer_name,customer_phone,customer_location,product_id,product_name,quantity,unit_price,payment_status,amount_paid,expected_collection_date) values(sid,aid,trim(p_customer_name),trim(p_customer_phone),trim(p_customer_location),pr.id,pr.name,p_quantity,p_unit_price,upper(p_payment_status),p_amount_paid,p_expected_collection_date) returning * into s;
 code:=lpad((floor(random()*900000)+100000)::int::text,6,'0'); exp:=now()+(hours||' hours')::interval;
 insert into public.mk_authenticators(sale_uuid,code_hash,expires_at) values(s.id,encode(digest(code,'sha256'),'hex'),exp);
 insert into public.mk_commissions(sale_uuid,advertiser_id,rate,amount) values(s.id,aid,rate,round(s.total_amount*rate/100,2));
 insert into public.mk_audit_logs(actor_id,action,entity_type,entity_id,metadata) values(uid,'SALE_CLAIM_CREATED','sale',s.id::text,jsonb_build_object('sale_id',sid,'advertiser_id',aid,'amount',s.total_amount));
 return jsonb_build_object('sale_id',sid,'authenticator_code',code,'total_amount',s.total_amount,'claim_expires_at',exp);
end; $$;
grant execute on function public.mk_create_sale_claim(uuid,text,text,uuid,integer,numeric,text,text,numeric,date) to authenticated;

create or replace function public.mk_verify_sale_claim(p_code text,p_customer_phone text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.mk_authenticators%rowtype; s public.mk_sales%rowtype;
begin
 if not public.mk_is_admin() then raise exception 'Only staff/admin can verify claims'; end if;
 select * into a from public.mk_authenticators where code_hash=encode(digest(trim(p_code),'sha256'),'hex') and used_at is null for update;
 if not found or a.expires_at<now() then raise exception 'Invalid, expired, or used code'; end if;
 select * into s from public.mk_sales where id=a.sale_uuid for update;
 if regexp_replace(s.customer_phone,'\D','','g') <> regexp_replace(trim(p_customer_phone),'\D','','g') then raise exception 'Customer phone does not match'; end if;
 update public.mk_sales set status='verified',verified_at=now(),verified_by=auth.uid() where id=s.id;
 insert into public.mk_audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'SALE_CLAIM_VERIFIED','sale',s.id::text,jsonb_build_object('sale_id',s.sale_id));
 return jsonb_build_object('sale_id',s.sale_id,'customer_name',s.customer_name,'customer_phone',s.customer_phone,'product_name',s.product_name,'quantity',s.quantity,'total_amount',s.total_amount,'amount_paid',s.amount_paid,'payment_status',s.payment_status,'status','verified');
end; $$;
grant execute on function public.mk_verify_sale_claim(text,text) to authenticated;

create or replace function public.mk_redeem_sale(p_sale_id text) returns jsonb language plpgsql security definer set search_path=public as $$
declare s public.mk_sales%rowtype; c public.mk_commissions%rowtype; allow_partial boolean;
begin
 if not public.mk_is_admin() then raise exception 'Only staff/admin can redeem'; end if;
 select * into s from public.mk_sales where sale_id=p_sale_id for update; if not found then raise exception 'Sale not found'; end if;
 if s.status<>'verified' then raise exception 'Sale must be verified first'; end if;
 select allow_partial_redeem into allow_partial from public.mk_settings where id=true;
 if s.payment_status='UNPAID' then raise exception 'Payment must be confirmed before redemption'; end if;
 if s.payment_status='PARTIAL' and not allow_partial then raise exception 'Partial payment is not allowed for redemption'; end if;
 update public.mk_sales set status='redeemed',redeemed_at=now(),redeemed_by=auth.uid() where id=s.id;
 update public.mk_authenticators set used_at=now() where sale_uuid=s.id;
 select * into c from public.mk_commissions where sale_uuid=s.id;
 insert into public.mk_audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'SALE_REDEEMED','sale',s.id::text,jsonb_build_object('sale_id',s.sale_id,'commission',c.amount));
 return jsonb_build_object('sale_id',s.sale_id,'commission_amount',c.amount);
end; $$;
grant execute on function public.mk_redeem_sale(text) to authenticated;

create or replace function public.mk_commission_action(p_commission_id uuid,p_status text,p_reference text default null,p_notes text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.mk_commissions%rowtype; s text:=upper(trim(p_status));
begin
 if not public.mk_is_super_admin() then raise exception 'Only Super Admin can change commission status'; end if;
 select * into c from public.mk_commissions where id=p_commission_id for update; if not found then raise exception 'Commission not found'; end if;
 if s='ELIGIBLE' then update public.mk_commissions set status='ELIGIBLE',eligible_at=now(),notes=coalesce(p_notes,notes),updated_at=now() where id=c.id;
 elsif s='PAID' then if c.status<>'ELIGIBLE' then raise exception 'Commission must be ELIGIBLE first'; end if; update public.mk_commissions set status='PAID',paid_at=now(),payment_reference=p_reference,notes=coalesce(p_notes,notes),updated_at=now() where id=c.id;
 else raise exception 'Invalid commission status'; end if;
 insert into public.mk_audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'COMMISSION_STATUS','commission',c.id::text,jsonb_build_object('status',s,'reference',p_reference));
 return jsonb_build_object('id',c.id,'status',s);
end; $$;
grant execute on function public.mk_commission_action(uuid,text,text,text) to authenticated;

create or replace function public.mk_save_settings(p_commission_rate numeric,p_claim_hours integer,p_allow_partial boolean,p_company_name text,p_logo_url text,p_primary text,p_secondary text,p_mode text,p_announcement text,p_features jsonb,p_order jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.mk_is_super_admin() then raise exception 'Only Super Admin can change settings'; end if;
 update public.mk_settings set commission_rate=p_commission_rate,claim_validity_hours=p_claim_hours,allow_partial_redeem=p_allow_partial,company_name=trim(p_company_name),logo_url=nullif(trim(p_logo_url),''),primary_color=p_primary,secondary_color=p_secondary,mode=p_mode,announcement=p_announcement,advertiser_features=coalesce(p_features,advertiser_features),advertiser_feature_order=coalesce(p_order,advertiser_feature_order),updated_at=now() where id=true;
 return jsonb_build_object('ok',true);
end; $$;
grant execute on function public.mk_save_settings(numeric,integer,boolean,text,text,text,text,text,text,jsonb,jsonb) to authenticated;

create or replace function public.mk_upsert_product(p_id uuid,p_name text,p_sku text,p_price numeric,p_active boolean,p_category text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare pid uuid; cid uuid;
begin
 if not public.mk_is_super_admin() then raise exception 'Only Super Admin can manage products'; end if;
 if nullif(trim(p_category),'') is not null then insert into public.mk_categories(name) values(trim(p_category)) on conflict(name) do update set name=excluded.name returning id into cid; end if;
 if p_id is null then insert into public.mk_products(name,sku,default_price,active,category_id) values(trim(p_name),nullif(trim(p_sku),''),p_price,p_active,cid) returning id into pid; else update public.mk_products set name=trim(p_name),sku=nullif(trim(p_sku),''),default_price=p_price,active=p_active,category_id=cid,updated_at=now() where id=p_id returning id into pid; end if;
 return jsonb_build_object('id',pid);
end; $$;
grant execute on function public.mk_upsert_product(uuid,text,text,numeric,boolean,text) to authenticated;

-- RLS: operational tables are accessed through policies; RPCs enforce sensitive writes.
alter table public.mk_settings enable row level security;
alter table public.mk_categories enable row level security;
alter table public.mk_products enable row level security;
alter table public.mk_advertiser_details enable row level security;
alter table public.mk_sales enable row level security;
alter table public.mk_authenticators enable row level security;
alter table public.mk_commissions enable row level security;
alter table public.mk_audit_logs enable row level security;

drop policy if exists mk_settings_read on public.mk_settings; create policy mk_settings_read on public.mk_settings for select to authenticated using (true);
drop policy if exists mk_settings_write on public.mk_settings; create policy mk_settings_write on public.mk_settings for all to authenticated using(public.mk_is_super_admin()) with check(public.mk_is_super_admin());
drop policy if exists mk_products_read on public.mk_products; create policy mk_products_read on public.mk_products for select to authenticated using(active or public.mk_is_admin());
drop policy if exists mk_categories_read on public.mk_categories; create policy mk_categories_read on public.mk_categories for select to authenticated using(active or public.mk_is_admin());
drop policy if exists mk_details_read on public.mk_advertiser_details; create policy mk_details_read on public.mk_advertiser_details for select to authenticated using(id=auth.uid() or public.mk_is_admin());
drop policy if exists mk_sales_read on public.mk_sales; create policy mk_sales_read on public.mk_sales for select to authenticated using(advertiser_id=auth.uid() or public.mk_is_admin());
drop policy if exists mk_comm_read on public.mk_commissions; create policy mk_comm_read on public.mk_commissions for select to authenticated using(advertiser_id=auth.uid() or public.mk_is_admin());
drop policy if exists mk_audit_read on public.mk_audit_logs; create policy mk_audit_read on public.mk_audit_logs for select to authenticated using(public.mk_is_super_admin());
drop policy if exists mk_auth_read on public.mk_authenticators; create policy mk_auth_read on public.mk_authenticators for select to authenticated using(public.mk_is_admin());

commit;
