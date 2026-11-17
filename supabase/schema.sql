-- AGUARIBAY · REINICIO (permite ejecutar este archivo todas las veces que quieras; borra los datos del sistema)
drop policy if exists cap_ins on storage.objects;
drop policy if exists cap_sel on storage.objects;
drop policy if exists pm_ins on storage.objects;
drop policy if exists pm_del on storage.objects;
drop policy if exists av_ins on storage.objects;
drop trigger if exists on_auth_user on auth.users;
drop table if exists auditoria,notificaciones,misiones_solicitudes,mov_puntos,canjes,visitas,promociones,sesiones_qr,profiles,config cascade;
drop function if exists es_staff(),es_admin(),handle_new_user(),distancia_m(float8,float8,float8,float8),solicitar_visita(float8,float8,text),resolver_visita(uuid,boolean,text),reclamar_premio(uuid),validar_canje(text),enviar_mision(text,text),resolver_mision(uuid,boolean,text),crear_sesion_qr(),suspender(uuid,boolean),stats(),hoy_ar(),cumple_en(date,int),cumples_proximos(int),mi_cumple(),_dar_cumple(uuid,boolean),guardar_nacimiento(date),entregar_regalo_cumple(uuid),eliminar_cliente(uuid),solicitar_visita(float8,float8),solicitar_canje(uuid,float8,float8),resolver_canje(uuid,boolean,text) cascade;
-- AGUARIBAY · esquema Supabase (ejecutar completo en SQL Editor)
create extension if not exists pgcrypto;
create table config(id int primary key default 1 check(id=1),nombre text default 'AGUARIBAY',color text default '#C9A36A',lat float8 default -34.6037,lng float8 default -58.3816,radio_m int default 60,horas_min int default 12,puntos_visita int default 10,sesion_min int default 60,bienvenida text default 'Nos encanta que vuelvas. Disfrutá tu experiencia y descubrí los beneficios que tenemos preparados para vos.',politicas text default '',hashtag text default '@aguaribay',redes text default 'Instagram, Facebook, TikTok',cumple_dias_antes int default 2,cumple_dias_despues int default 3,cumple_visitas_min int default 20,mision_activa boolean default true,mision_puntos int default 20,mision_ventana_dias int default 1);
insert into config(id) values(1);
create table profiles(id uuid primary key references auth.users on delete cascade,email text,nombre text,apellido text,telefono text,foto_url text,codigo_cliente text unique default upper(substr(md5(random()::text),1,8)),rol text not null default 'cliente' check(rol in('cliente','staff','admin')),suspendido boolean default false,puntos int default 0,visitas int default 0,consentimiento_ubicacion boolean default false,fecha_nacimiento date,creado timestamptz default now());
create table sesiones_qr(codigo text primary key,vence timestamptz not null,creado_por uuid,creada timestamptz default now());
create table promociones(id uuid primary key default gen_random_uuid(),nombre text not null,descripcion text,imagen_url text,condiciones text,tipo text default 'visitas',visitas_req int default 0,puntos_req int default 0,inicio timestamptz,fin timestamptz,stock int,limite_cliente int default 1,activa boolean default true,creada timestamptz default now());
create table visitas(id uuid primary key default gen_random_uuid(),cliente_id uuid not null references profiles(id),estado text default 'pendiente' check(estado in('pendiente','aprobada','rechazada')),lat float8,lng float8,distancia_m float8,sospechosa boolean default false,codigo_sesion text,creada timestamptz default now(),revisada_por uuid,revisada_en timestamptz,motivo_rechazo text);
create table canjes(id uuid primary key default gen_random_uuid(),cliente_id uuid not null references profiles(id),promo_id uuid references promociones(id) on delete set null,promo_nombre text,codigo text unique not null,estado text default 'pendiente' check(estado in('pendiente','solicitado','canjeado')),creado timestamptz default now(),canjeado_por uuid,canjeado_en timestamptz,vence timestamptz,anio int,semana date,solicitado_en timestamptz);
create table mov_puntos(id bigserial primary key,cliente_id uuid references profiles(id),delta int,motivo text,ref uuid,creado timestamptz default now());
create table misiones_solicitudes(id uuid primary key default gen_random_uuid(),cliente_id uuid not null references profiles(id),visita_id uuid references visitas(id),imagen_path text,hash text unique,estado text default 'pendiente' check(estado in('pendiente','aprobada','rechazada')),creada timestamptz default now(),revisor uuid,revisada_en timestamptz,motivo_rechazo text);
create table notificaciones(id bigserial primary key,user_id uuid references profiles(id),titulo text,cuerpo text,leida boolean default false,creada timestamptz default now());
create table auditoria(id bigserial primary key,actor uuid,accion text,detalle jsonb,creada timestamptz default now());

create unique index canjes_cumple_u on canjes(cliente_id,promo_id,anio) where anio is not null;
create unique index canjes_semana_u on canjes(cliente_id,promo_id,semana) where semana is not null;
create function es_staff() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and rol in('staff','admin') and not suspendido) $$;
create function es_admin() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and rol='admin' and not suspendido) $$;
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$ declare nac date; begin
begin nac:=nullif(new.raw_user_meta_data->>'nacimiento','')::date; exception when others then nac:=null; end;
if nac is not null and (nac>current_date or nac<date '1900-01-01') then nac:=null; end if;
insert into profiles(id,email,nombre,apellido,telefono,fecha_nacimiento) values(new.id,new.email,new.raw_user_meta_data->>'nombre',new.raw_user_meta_data->>'apellido',new.raw_user_meta_data->>'telefono',nac); return new; end $$;
create trigger on_auth_user after insert on auth.users for each row execute function handle_new_user();
create function distancia_m(a float8,b float8,c float8,d float8) returns float8 language sql immutable as $$ select 6371000*2*asin(sqrt(sin(radians(c-a)/2)^2+cos(radians(a))*cos(radians(c))*sin(radians(d-b)/2)^2)) $$;

-- Visitas: validación en servidor (código de sesión + distancia + duplicados + antifraude)
create function solicitar_visita(p_lat float8,p_lng float8) returns uuid language plpgsql security definer set search_path=public as $$
declare c config; d float8; v_id uuid; sus boolean; begin
if auth.uid() is null or (select suspendido from profiles where id=auth.uid()) then raise exception 'Cuenta no habilitada.'; end if;
select * into c from config where id=1;
d:=distancia_m(p_lat,p_lng,c.lat,c.lng);
if d>c.radio_m then raise exception 'Para registrar tu visita, necesitás estar en AGUARIBAY.'; end if;
update visitas set estado='rechazada',motivo_rechazo='Venció sin aprobación',revisada_en=now() where cliente_id=auth.uid() and estado='pendiente' and creada<now()-interval '30 minutes';
if exists(select 1 from visitas where cliente_id=auth.uid() and (estado='pendiente' or (estado='aprobada' and creada>now()-c.horas_min*interval '1 hour'))) then raise exception 'Ya tenés una visita pendiente o reciente.'; end if;
sus:= d<0.5 or exists(select 1 from visitas where lat=p_lat and lng=p_lng and cliente_id<>auth.uid() and creada>now()-interval '1 day');
insert into visitas(cliente_id,lat,lng,distancia_m,sospechosa) values(auth.uid(),p_lat,p_lng,d,sus) returning id into v_id; return v_id; end $$;

create function resolver_visita(p_id uuid,p_ok boolean,p_motivo text default null) returns void language plpgsql security definer set search_path=public as $$
declare v visitas; c config; nv int; pr promociones; cod text; ws date; rc int; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
select * into v from visitas where id=p_id for update;
if v.id is null or v.estado<>'pendiente' then raise exception 'La solicitud ya fue resuelta.'; end if;
select * into c from config where id=1;
if p_ok and v.creada<now()-interval '30 minutes' then raise exception 'La solicitud venció (más de 30 minutos). Pedile al cliente que la envíe de nuevo estando en el local.'; end if;
if p_ok and v.distancia_m>c.radio_m then raise exception 'El cliente no estaba dentro del local al solicitar la visita.'; end if;
update visitas set estado=case when p_ok then 'aprobada' else 'rechazada' end,revisada_por=auth.uid(),revisada_en=now(),motivo_rechazo=p_motivo where id=p_id;
if p_ok then update profiles set visitas=visitas+1,puntos=puntos+c.puntos_visita where id=v.cliente_id returning visitas into nv;
 insert into mov_puntos(cliente_id,delta,motivo,ref) values(v.cliente_id,c.puntos_visita,'Visita aprobada',p_id);
 for pr in select * from promociones where activa and tipo='visitas' and puntos_req=0 and visitas_req=nv and (inicio is null or inicio<=now()) and (fin is null or fin>=now()) and (stock is null or stock>0) loop
  if pr.limite_cliente is null or (select count(*) from canjes where cliente_id=v.cliente_id and promo_id=pr.id)<pr.limite_cliente then
   cod:=upper(substr(md5(random()::text||clock_timestamp()::text),1,8));
   insert into canjes(cliente_id,promo_id,promo_nombre,codigo) values(v.cliente_id,pr.id,pr.nombre,cod);
   if pr.stock is not null then update promociones set stock=stock-1 where id=pr.id; end if;
   insert into notificaciones(user_id,titulo,cuerpo) values(v.cliente_id,'¡Premio desbloqueado!',pr.nombre||' · ya está disponible en Tus premios');
  end if;
 end loop;
 if (select count(distinct extract(isodow from (k.creada at time zone 'America/Argentina/Buenos_Aires'))) from visitas k where k.cliente_id=v.cliente_id and k.estado='aprobada' and date_trunc('week',k.creada at time zone 'America/Argentina/Buenos_Aires')=date_trunc('week',v.creada at time zone 'America/Argentina/Buenos_Aires') and extract(isodow from (k.creada at time zone 'America/Argentina/Buenos_Aires'))<=6)=6 then
  ws:=date_trunc('week',v.creada at time zone 'America/Argentina/Buenos_Aires')::date;
  for pr in select * from promociones where activa and tipo='semana' and (stock is null or stock>0) and (inicio is null or inicio<=now()) and (fin is null or fin>=now()) loop
   cod:=upper(substr(md5(random()::text||clock_timestamp()::text),1,8));
   insert into canjes(cliente_id,promo_id,promo_nombre,codigo,semana) values(v.cliente_id,pr.id,pr.nombre,cod,ws) on conflict (cliente_id,promo_id,semana) where semana is not null do nothing;
   get diagnostics rc=row_count;
   if rc>0 then
    if pr.stock is not null then update promociones set stock=stock-1 where id=pr.id; end if;
    insert into notificaciones(user_id,titulo,cuerpo) values(v.cliente_id,'📅 ¡Semana completa!',pr.nombre||' · ya está disponible en Tus premios');
   end if;
  end loop;
 end if;
 end if;
insert into notificaciones(user_id,titulo,cuerpo) values(v.cliente_id,case when p_ok then '¡Visita aprobada!' else 'Visita rechazada' end,case when p_ok then 'Sumaste un sello y '||c.puntos_visita||' puntos.' else coalesce(p_motivo,'Consultá con el personal.') end);
insert into auditoria(actor,accion,detalle) values(auth.uid(),case when p_ok then 'visita_aprobada' else 'visita_rechazada' end,jsonb_build_object('id',p_id,'motivo',p_motivo)); end $$;

-- Premios y canjes
create function reclamar_premio(p_id uuid) returns text language plpgsql security definer set search_path=public as $$
declare p promociones; pr profiles; cod text; n int; begin
select * into pr from profiles where id=auth.uid() for update;
if pr.suspendido then raise exception 'Cuenta suspendida.'; end if;
select * into p from promociones where id=p_id for update;
if p.id is null or not p.activa or p.inicio>now() or p.fin<now() then raise exception 'Premio no disponible.'; end if;
if p.tipo in('cumple','semana') then raise exception 'Este premio se entrega automáticamente.'; end if;
if p.stock is not null and p.stock<=0 then raise exception 'Premio agotado.'; end if;
if pr.visitas<p.visitas_req or pr.puntos<p.puntos_req then raise exception 'Todavía no alcanzaste los requisitos.'; end if;
select count(*) into n from canjes where cliente_id=pr.id and promo_id=p.id;
if p.limite_cliente is not null and n>=p.limite_cliente then raise exception 'Alcanzaste el límite de este premio.'; end if;
cod:=upper(substr(md5(random()::text||clock_timestamp()::text),1,8));
insert into canjes(cliente_id,promo_id,promo_nombre,codigo) values(pr.id,p.id,p.nombre,cod);
update profiles set puntos=puntos-p.puntos_req where id=pr.id;
if p.stock is not null then update promociones set stock=stock-1 where id=p.id; end if;
if p.puntos_req>0 then insert into mov_puntos(cliente_id,delta,motivo,ref) values(pr.id,-p.puntos_req,'Premio: '||p.nombre,p.id); end if;
insert into notificaciones(user_id,titulo,cuerpo) values(pr.id,'¡Premio desbloqueado!',p.nombre||' · ya está disponible en Tus premios');
return cod; end $$;


-- Misión "Compartí tu café"
create function enviar_mision(p_path text,p_hash text) returns uuid language plpgsql security definer set search_path=public as $$
declare c config; v uuid; r uuid; begin
select * into c from config where id=1;
if not c.mision_activa then raise exception 'La misión no está activa.'; end if;
if (select suspendido from profiles where id=auth.uid()) then raise exception 'Cuenta suspendida.'; end if;
select vi.id into v from visitas vi where vi.cliente_id=auth.uid() and vi.estado='aprobada' and vi.revisada_en>now()-c.mision_ventana_dias*interval '1 day' and not exists(select 1 from misiones_solicitudes m where m.visita_id=vi.id and m.estado<>'rechazada') order by vi.revisada_en desc limit 1;
if v is null then raise exception 'Necesitás una visita aprobada reciente sin misión usada.'; end if;
insert into misiones_solicitudes(cliente_id,visita_id,imagen_path,hash) values(auth.uid(),v,p_path,p_hash) returning id into r; return r;
exception when unique_violation then raise exception 'Esa captura ya fue enviada.'; end $$;

create function resolver_mision(p_id uuid,p_ok boolean,p_motivo text default null) returns void language plpgsql security definer set search_path=public as $$
declare m misiones_solicitudes; c config; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
select * into m from misiones_solicitudes where id=p_id for update;
if m.id is null or m.estado<>'pendiente' then raise exception 'Ya fue resuelta.'; end if;
select * into c from config where id=1;
update misiones_solicitudes set estado=case when p_ok then 'aprobada' else 'rechazada' end,revisor=auth.uid(),revisada_en=now(),motivo_rechazo=p_motivo where id=p_id;
if p_ok then update profiles set puntos=puntos+c.mision_puntos where id=m.cliente_id; insert into mov_puntos(cliente_id,delta,motivo,ref) values(m.cliente_id,c.mision_puntos,'Misión Compartí tu café',p_id); end if;
insert into notificaciones(user_id,titulo,cuerpo) values(m.cliente_id,case when p_ok then '¡Misión aprobada!' else 'Misión rechazada' end,case when p_ok then 'Ganaste '||c.mision_puntos||' puntos extra.' else coalesce(p_motivo,'Revisá las condiciones.') end);
insert into auditoria(actor,accion,detalle) values(auth.uid(),case when p_ok then 'mision_aprobada' else 'mision_rechazada' end,jsonb_build_object('id',p_id)); end $$;

create function crear_sesion_qr() returns text language plpgsql security definer set search_path=public as $$
declare cod text; m int; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
select sesion_min into m from config where id=1;
cod:=lpad(floor(random()*1000000)::int::text,6,'0');
insert into sesiones_qr(codigo,vence,creado_por) values(cod,now()+m*interval '1 minute',auth.uid()); return cod; end $$;

create function suspender(p_uid uuid,p_val boolean) returns void language plpgsql security definer set search_path=public as $$
begin if not es_admin() then raise exception 'Solo el administrador.'; end if;
update profiles set suspendido=p_val where id=p_uid and rol='cliente';
insert into auditoria(actor,accion,detalle) values(auth.uid(),'suspension',jsonb_build_object('cliente',p_uid,'valor',p_val)); end $$;

create function stats() returns json language sql security definer set search_path=public as $$
select json_build_object('clientes',(select count(*) from profiles where rol='cliente'),'visitas_hoy',(select count(*) from visitas where creada::date=current_date),'pendientes',(select count(*) from visitas where estado='pendiente'),'aprobadas',(select count(*) from visitas where estado='aprobada'),'canjes',(select count(*) from canjes where estado='canjeado'),'canjes_sol',(select count(*) from canjes where estado='solicitado'),'promos',(select count(*) from promociones where activa)) where es_staff() $$;

-- Cumpleaños (hora de Argentina; el cálculo se hace al momento, sin depender de tareas programadas)
create function hoy_ar() returns date language sql stable as $$ select (now() at time zone 'America/Argentina/Buenos_Aires')::date $$;
create function cumple_en(nac date,y int) returns date language sql immutable as $$ select case when extract(month from nac)=2 and extract(day from nac)=29 and not (y%4=0 and (y%100<>0 or y%400=0)) then make_date(y,2,28) else make_date(y,extract(month from nac)::int,extract(day from nac)::int) end $$;
create function _dar_cumple(p_uid uuid,p_force boolean) returns int language plpgsql security definer set search_path=public as $$
declare h date:=hoy_ar(); c config; p profiles; f date; y int; pr promociones; cod text; n int:=0; rc int; v12 int; begin
select * into p from profiles where id=p_uid; select * into c from config where id=1;
if p.id is null or p.suspendido or p.fecha_nacimiento is null then return 0; end if;
select count(*) into v12 from visitas where cliente_id=p_uid and estado='aprobada' and creada>=now()-interval '1 year';
if v12<c.cumple_visitas_min then return 0; end if;
f:=case when cumple_en(p.fecha_nacimiento,extract(year from h)::int)>=h-c.cumple_dias_despues then cumple_en(p.fecha_nacimiento,extract(year from h)::int) else cumple_en(p.fecha_nacimiento,extract(year from h)::int+1) end;
y:=extract(year from f)::int;
if not p_force and (f-h)>c.cumple_dias_antes then return 0; end if;
for pr in select * from promociones where activa and tipo='cumple' and (stock is null or stock>0) and (inicio is null or inicio<=now()) and (fin is null or fin>=now()) loop
 cod:=upper(substr(md5(random()::text||clock_timestamp()::text),1,8));
 insert into canjes(cliente_id,promo_id,promo_nombre,codigo,vence,anio) values(p.id,pr.id,pr.nombre,cod,((f+c.cumple_dias_despues+1)::timestamp at time zone 'America/Argentina/Buenos_Aires'),y) on conflict (cliente_id,promo_id,anio) where anio is not null do nothing;
 get diagnostics rc=row_count;
 if rc>0 then n:=n+1;
  if pr.stock is not null then update promociones set stock=stock-1 where id=pr.id; end if;
  insert into notificaciones(user_id,titulo,cuerpo) values(p.id,'🎂 ¡Tenemos un regalo por tu cumpleaños!',pr.nombre||' · ya está disponible en Tus premios');
 end if;
end loop; return n; end $$;
revoke all on function _dar_cumple(uuid,boolean) from public,anon,authenticated;
create function mi_cumple() returns json language plpgsql security definer set search_path=public as $$
declare h date:=hoy_ar(); c config; p profiles; f date; n int; v12 int; begin
if auth.uid() is null then return null; end if;
select * into p from profiles where id=auth.uid(); select * into c from config where id=1;
if p.fecha_nacimiento is null then return json_build_object('nac',false); end if;
f:=case when cumple_en(p.fecha_nacimiento,extract(year from h)::int)>=h-c.cumple_dias_despues then cumple_en(p.fecha_nacimiento,extract(year from h)::int) else cumple_en(p.fecha_nacimiento,extract(year from h)::int+1) end;
n:=_dar_cumple(auth.uid(),false);
select count(*) into v12 from visitas where cliente_id=auth.uid() and estado='aprobada' and creada>=now()-interval '1 year';
return json_build_object('nac',true,'dias',f-h,'fecha',f,'nuevos',n,'vis',v12,'req',c.cumple_visitas_min,'apto',v12>=c.cumple_visitas_min); end $$;
create function guardar_nacimiento(p_fecha date) returns void language plpgsql security definer set search_path=public as $$ begin
if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
if p_fecha is null or p_fecha>current_date or p_fecha<date '1900-01-01' then raise exception 'Fecha inválida.'; end if;
update profiles set fecha_nacimiento=p_fecha where id=auth.uid() and fecha_nacimiento is null;
if not found then raise exception 'Tu fecha de nacimiento ya está cargada. Si hay un error, pedile ayuda al personal.'; end if; end $$;
create function entregar_regalo_cumple(p_cliente uuid) returns int language plpgsql security definer set search_path=public as $$
declare n int; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
if (select count(*) from visitas where cliente_id=p_cliente and estado='aprobada' and creada>=now()-interval '1 year')<(select cumple_visitas_min from config where id=1) then raise exception 'El cliente no alcanza el mínimo de visitas aprobadas del último año para el regalo.'; end if;
n:=_dar_cumple(p_cliente,true);
insert into auditoria(actor,accion,detalle) values(auth.uid(),'regalo_cumple',jsonb_build_object('cliente',p_cliente,'entregados',n)); return n; end $$;
create function cumples_proximos(p_dias int default 7) returns json language plpgsql security definer set search_path=public as $$
declare h date:=hoy_ar(); c config; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
select * into c from config where id=1;
return coalesce((select json_agg(x order by x.dias) from (
 select p.id,p.nombre,p.apellido,p.foto_url,p.telefono,f.d as fecha,(f.d-h) as dias,(extract(year from f.d)::int-extract(year from p.fecha_nacimiento)::int) as edad,
  exists(select 1 from canjes k join promociones pr on pr.id=k.promo_id where k.cliente_id=p.id and k.anio=extract(year from f.d)::int and pr.tipo='cumple') as regalo,(select count(*) from visitas v where v.cliente_id=p.id and v.estado='aprobada' and v.creada>=now()-interval '1 year') as vis,c.cumple_visitas_min as req
 from profiles p cross join lateral (select case when cumple_en(p.fecha_nacimiento,extract(year from h)::int)>=h-c.cumple_dias_despues then cumple_en(p.fecha_nacimiento,extract(year from h)::int) else cumple_en(p.fecha_nacimiento,extract(year from h)::int+1) end as d) f
 where p.rol='cliente' and not p.suspendido and p.fecha_nacimiento is not null and (f.d-h)<=p_dias) x),'[]'::json); end $$;

create function eliminar_cliente(p_uid uuid) returns void language plpgsql security definer set search_path=public as $$
declare p profiles; begin
if not es_admin() then raise exception 'Solo el administrador puede eliminar clientes.'; end if;
select * into p from profiles where id=p_uid;
if p.id is null or p.rol<>'cliente' then raise exception 'Solo se pueden eliminar clientes.'; end if;
delete from notificaciones where user_id=p_uid; delete from mov_puntos where cliente_id=p_uid; delete from misiones_solicitudes where cliente_id=p_uid; delete from canjes where cliente_id=p_uid; delete from visitas where cliente_id=p_uid;
delete from profiles where id=p_uid;
delete from auth.users where id=p_uid;
insert into auditoria(actor,accion,detalle) values(auth.uid(),'cliente_eliminado',jsonb_build_object('email',p.email,'nombre',p.nombre,'apellido',p.apellido)); end $$;

create function solicitar_canje(p_id uuid,p_lat float8,p_lng float8) returns void language plpgsql security definer set search_path=public as $$
declare k canjes; c config; begin
if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
select * into k from canjes where id=p_id and cliente_id=auth.uid() for update;
if k.id is null then raise exception 'Premio no encontrado.'; end if;
if k.estado<>'pendiente' then raise exception 'Este premio ya fue solicitado o canjeado.'; end if;
if k.vence is not null and k.vence<now() then raise exception 'Este premio venció.'; end if;
if (select suspendido from profiles where id=auth.uid()) then raise exception 'Cuenta suspendida.'; end if;
select * into c from config where id=1;
if distancia_m(p_lat,p_lng,c.lat,c.lng)>c.radio_m then raise exception 'Para canjear, necesitás estar en AGUARIBAY.'; end if;
update canjes set estado='solicitado',solicitado_en=now() where id=p_id; end $$;
create function resolver_canje(p_id uuid,p_ok boolean,p_motivo text default null) returns void language plpgsql security definer set search_path=public as $$
declare k canjes; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
select * into k from canjes where id=p_id for update;
if k.id is null or k.estado<>'solicitado' then raise exception 'Este canje ya fue resuelto.'; end if;
if p_ok then
 update canjes set estado='canjeado',canjeado_por=auth.uid(),canjeado_en=now() where id=p_id;
 insert into notificaciones(user_id,titulo,cuerpo) values(k.cliente_id,'✅ ¡Premio canjeado!',k.promo_nombre);
else
 update canjes set estado='pendiente',solicitado_en=null where id=p_id;
 insert into notificaciones(user_id,titulo,cuerpo) values(k.cliente_id,'Canje no aprobado',coalesce(p_motivo,'Consultá con el personal. Tu premio sigue disponible.'));
end if;
insert into auditoria(actor,accion,detalle) values(auth.uid(),case when p_ok then 'canje_aprobado' else 'canje_rechazado' end,jsonb_build_object('id',p_id,'motivo',p_motivo)); end $$;

-- RLS
alter table config enable row level security;alter table profiles enable row level security;alter table sesiones_qr enable row level security;alter table promociones enable row level security;alter table visitas enable row level security;alter table canjes enable row level security;alter table mov_puntos enable row level security;alter table misiones_solicitudes enable row level security;alter table notificaciones enable row level security;alter table auditoria enable row level security;
create policy c_sel on config for select using(true);
create policy c_upd on config for update using(es_admin());
create policy p_sel on profiles for select using(id=auth.uid() or es_staff());
create policy p_upd on profiles for update using(id=auth.uid());
revoke update on profiles from anon,authenticated;
grant update(nombre,apellido,telefono,foto_url,consentimiento_ubicacion) on profiles to authenticated;
create policy q_sel on sesiones_qr for select using(es_staff());
create policy pr_sel on promociones for select using(activa or es_staff());
create policy pr_all on promociones for all using(es_admin()) with check(es_admin());
create policy v_sel on visitas for select using(cliente_id=auth.uid() or es_staff());
create policy cj_sel on canjes for select using(cliente_id=auth.uid() or es_staff());
create policy m_sel on mov_puntos for select using(cliente_id=auth.uid() or es_staff());
create policy ms_sel on misiones_solicitudes for select using(cliente_id=auth.uid() or es_staff());
create policy n_sel on notificaciones for select using(user_id=auth.uid());
create policy n_upd on notificaciones for update using(user_id=auth.uid());
revoke update on notificaciones from anon,authenticated;grant update(leida) on notificaciones to authenticated;
create policy a_sel on auditoria for select using(es_admin());
revoke insert,delete on all tables in schema public from anon,authenticated;
grant insert,update,delete on promociones to authenticated;grant update on config to authenticated;
-- Storage privado para capturas
insert into storage.buckets(id,name,public) values('capturas','capturas',false) on conflict do nothing;
create policy cap_ins on storage.objects for insert to authenticated with check(bucket_id='capturas' and (storage.foldername(name))[1]=auth.uid()::text);
create policy cap_sel on storage.objects for select to authenticated using(bucket_id='capturas' and ((storage.foldername(name))[1]=auth.uid()::text or es_staff()));
alter publication supabase_realtime add table visitas,notificaciones,canjes;
-- Para crear el primer administrador (después de registrarte en la web):
-- update profiles set rol='admin' where email='tu@correo.com';

-- Recupera cuentas creadas antes de este reinicio
insert into profiles(id,email,nombre,apellido,telefono) select id,email,raw_user_meta_data->>'nombre',raw_user_meta_data->>'apellido',raw_user_meta_data->>'telefono' from auth.users on conflict do nothing;

-- Imágenes: premios (solo admin sube) y fotos de perfil (cada cliente en su carpeta). Lectura pública.
insert into storage.buckets(id,name,public) values('promos','promos',true),('avatares','avatares',true) on conflict(id) do update set public=true;
create policy pm_ins on storage.objects for insert to authenticated with check(bucket_id='promos' and es_admin());
create policy pm_del on storage.objects for delete to authenticated using(bucket_id='promos' and es_admin());
create policy av_ins on storage.objects for insert to authenticated with check(bucket_id='avatares' and (storage.foldername(name))[1]=auth.uid()::text);

-- Administradores (contraseña inicial: 987654321 · cambiala desde Más → Mi cuenta)
do $$ declare u record; uid uuid; begin
for u in select * from (values('admin@gmail.com','Administrador'),('betsabe@gmail.com','Betsabe'),('aguaribay23@gmail.com','Aguaribay')) t(email,nombre) loop
 select id into uid from auth.users where email=u.email;
 if uid is null then
  uid:=gen_random_uuid();
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated',u.email,crypt('987654321',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}',jsonb_build_object('nombre',u.nombre,'apellido','','telefono',''),now(),now(),'','','','');
  insert into auth.identities(id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  values(gen_random_uuid(),uid,uid::text,jsonb_build_object('sub',uid::text,'email',u.email,'email_verified',true),'email',now(),now(),now());
 else
  update auth.users set encrypted_password=crypt('987654321',gen_salt('bf')),email_confirmed_at=coalesce(email_confirmed_at,now()) where id=uid;
 end if;
 insert into profiles(id,email,nombre,apellido,telefono,rol) values(uid,u.email,u.nombre,'','','admin') on conflict(id) do update set rol='admin',suspendido=false;
end loop; end $$;
