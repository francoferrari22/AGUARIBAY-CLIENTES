-- Cumpleaños + sellos semanales, SIN borrar datos
alter table profiles add column if not exists fecha_nacimiento date;
alter table config add column if not exists cumple_dias_antes int default 2;
alter table config add column if not exists cumple_dias_despues int default 3;
alter table canjes add column if not exists vence timestamptz;
alter table canjes add column if not exists anio int;
alter table canjes add column if not exists semana date;
-- Permite borrar premios para siempre (los canjes ya entregados se conservan)
alter table canjes drop constraint if exists canjes_promo_id_fkey;
alter table canjes add constraint canjes_promo_id_fkey foreign key(promo_id) references promociones(id) on delete set null;
create unique index if not exists canjes_cumple_u on canjes(cliente_id,promo_id,anio) where anio is not null;
create unique index if not exists canjes_semana_u on canjes(cliente_id,promo_id,semana) where semana is not null;
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$ declare nac date; begin
begin nac:=nullif(new.raw_user_meta_data->>'nacimiento','')::date; exception when others then nac:=null; end;
if nac is not null and (nac>current_date or nac<date '1900-01-01') then nac:=null; end if;
insert into profiles(id,email,nombre,apellido,telefono,fecha_nacimiento) values(new.id,new.email,new.raw_user_meta_data->>'nombre',new.raw_user_meta_data->>'apellido',new.raw_user_meta_data->>'telefono',nac); return new; end $$;

create or replace function resolver_visita(p_id uuid,p_ok boolean,p_motivo text default null) returns void language plpgsql security definer set search_path=public as $$
declare v visitas; c config; nv int; pr promociones; cod text; ws date; rc int; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
select * into v from visitas where id=p_id for update;
if v.id is null or v.estado<>'pendiente' then raise exception 'La solicitud ya fue resuelta.'; end if;
select * into c from config where id=1;
update visitas set estado=case when p_ok then 'aprobada' else 'rechazada' end,revisada_por=auth.uid(),revisada_en=now(),motivo_rechazo=p_motivo where id=p_id;
if p_ok then update profiles set visitas=visitas+1,puntos=puntos+c.puntos_visita where id=v.cliente_id returning visitas into nv;
 insert into mov_puntos(cliente_id,delta,motivo,ref) values(v.cliente_id,c.puntos_visita,'Visita aprobada',p_id);
 for pr in select * from promociones where activa and tipo='visitas' and puntos_req=0 and visitas_req=nv and (inicio is null or inicio<=now()) and (fin is null or fin>=now()) and (stock is null or stock>0) loop
  if pr.limite_cliente is null or (select count(*) from canjes where cliente_id=v.cliente_id and promo_id=pr.id)<pr.limite_cliente then
   cod:=upper(substr(md5(random()::text||clock_timestamp()::text),1,8));
   insert into canjes(cliente_id,promo_id,promo_nombre,codigo) values(v.cliente_id,pr.id,pr.nombre,cod);
   if pr.stock is not null then update promociones set stock=stock-1 where id=pr.id; end if;
   insert into notificaciones(user_id,titulo,cuerpo) values(v.cliente_id,'¡Premio desbloqueado!',pr.nombre||' · código '||cod);
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
    insert into notificaciones(user_id,titulo,cuerpo) values(v.cliente_id,'📅 ¡Semana completa!',pr.nombre||' · código '||cod);
   end if;
  end loop;
 end if;
 end if;
insert into notificaciones(user_id,titulo,cuerpo) values(v.cliente_id,case when p_ok then '¡Visita aprobada!' else 'Visita rechazada' end,case when p_ok then 'Sumaste un sello y '||c.puntos_visita||' puntos.' else coalesce(p_motivo,'Consultá con el personal.') end);
insert into auditoria(actor,accion,detalle) values(auth.uid(),case when p_ok then 'visita_aprobada' else 'visita_rechazada' end,jsonb_build_object('id',p_id,'motivo',p_motivo)); end $$;

create or replace function validar_canje(p_codigo text) returns text language plpgsql security definer set search_path=public as $$
declare r canjes; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
update canjes set estado='canjeado',canjeado_por=auth.uid(),canjeado_en=now() where codigo=upper(trim(p_codigo)) and estado='pendiente' and (vence is null or vence>now()) returning * into r;
if r.id is null then raise exception 'Código inexistente, ya utilizado o vencido.'; end if;
insert into auditoria(actor,accion,detalle) values(auth.uid(),'canje_validado',jsonb_build_object('codigo',r.codigo));
return r.promo_nombre; end $$;

create or replace function reclamar_premio(p_id uuid) returns text language plpgsql security definer set search_path=public as $$
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
insert into notificaciones(user_id,titulo,cuerpo) values(pr.id,'¡Premio desbloqueado!',p.nombre||' · código '||cod);
return cod; end $$;

create or replace function hoy_ar() returns date language sql stable as $$ select (now() at time zone 'America/Argentina/Buenos_Aires')::date $$;

create or replace function cumple_en(nac date,y int) returns date language sql immutable as $$ select case when extract(month from nac)=2 and extract(day from nac)=29 and not (y%4=0 and (y%100<>0 or y%400=0)) then make_date(y,2,28) else make_date(y,extract(month from nac)::int,extract(day from nac)::int) end $$;

create or replace function _dar_cumple(p_uid uuid,p_force boolean) returns int language plpgsql security definer set search_path=public as $$
declare h date:=hoy_ar(); c config; p profiles; f date; y int; pr promociones; cod text; n int:=0; rc int; begin
select * into p from profiles where id=p_uid; select * into c from config where id=1;
if p.id is null or p.suspendido or p.fecha_nacimiento is null then return 0; end if;
f:=case when cumple_en(p.fecha_nacimiento,extract(year from h)::int)>=h-c.cumple_dias_despues then cumple_en(p.fecha_nacimiento,extract(year from h)::int) else cumple_en(p.fecha_nacimiento,extract(year from h)::int+1) end;
y:=extract(year from f)::int;
if not p_force and (f-h)>c.cumple_dias_antes then return 0; end if;
for pr in select * from promociones where activa and tipo='cumple' and (stock is null or stock>0) and (inicio is null or inicio<=now()) and (fin is null or fin>=now()) loop
 cod:=upper(substr(md5(random()::text||clock_timestamp()::text),1,8));
 insert into canjes(cliente_id,promo_id,promo_nombre,codigo,vence,anio) values(p.id,pr.id,pr.nombre,cod,((f+c.cumple_dias_despues+1)::timestamp at time zone 'America/Argentina/Buenos_Aires'),y) on conflict (cliente_id,promo_id,anio) where anio is not null do nothing;
 get diagnostics rc=row_count;
 if rc>0 then n:=n+1;
  if pr.stock is not null then update promociones set stock=stock-1 where id=pr.id; end if;
  insert into notificaciones(user_id,titulo,cuerpo) values(p.id,'🎂 ¡Tenemos un regalo por tu cumpleaños!',pr.nombre||' · código '||cod);
 end if;
end loop; return n; end $$;

create or replace function mi_cumple() returns json language plpgsql security definer set search_path=public as $$
declare h date:=hoy_ar(); c config; p profiles; f date; n int; begin
if auth.uid() is null then return null; end if;
select * into p from profiles where id=auth.uid(); select * into c from config where id=1;
if p.fecha_nacimiento is null then return json_build_object('nac',false); end if;
f:=case when cumple_en(p.fecha_nacimiento,extract(year from h)::int)>=h-c.cumple_dias_despues then cumple_en(p.fecha_nacimiento,extract(year from h)::int) else cumple_en(p.fecha_nacimiento,extract(year from h)::int+1) end;
n:=_dar_cumple(auth.uid(),false);
return json_build_object('nac',true,'dias',f-h,'fecha',f,'nuevos',n); end $$;

create or replace function guardar_nacimiento(p_fecha date) returns void language plpgsql security definer set search_path=public as $$ begin
if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
if p_fecha is null or p_fecha>current_date or p_fecha<date '1900-01-01' then raise exception 'Fecha inválida.'; end if;
update profiles set fecha_nacimiento=p_fecha where id=auth.uid() and fecha_nacimiento is null;
if not found then raise exception 'Tu fecha de nacimiento ya está cargada. Si hay un error, pedile ayuda al personal.'; end if; end $$;

create or replace function entregar_regalo_cumple(p_cliente uuid) returns int language plpgsql security definer set search_path=public as $$
declare n int; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
n:=_dar_cumple(p_cliente,true);
insert into auditoria(actor,accion,detalle) values(auth.uid(),'regalo_cumple',jsonb_build_object('cliente',p_cliente,'entregados',n)); return n; end $$;

create or replace function cumples_proximos(p_dias int default 7) returns json language plpgsql security definer set search_path=public as $$
declare h date:=hoy_ar(); c config; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
select * into c from config where id=1;
return coalesce((select json_agg(x order by x.dias) from (
 select p.id,p.nombre,p.apellido,p.foto_url,p.telefono,f.d as fecha,(f.d-h) as dias,(extract(year from f.d)::int-extract(year from p.fecha_nacimiento)::int) as edad,
  exists(select 1 from canjes k join promociones pr on pr.id=k.promo_id where k.cliente_id=p.id and k.anio=extract(year from f.d)::int and pr.tipo='cumple') as regalo
 from profiles p cross join lateral (select case when cumple_en(p.fecha_nacimiento,extract(year from h)::int)>=h-c.cumple_dias_despues then cumple_en(p.fecha_nacimiento,extract(year from h)::int) else cumple_en(p.fecha_nacimiento,extract(year from h)::int+1) end as d) f
 where p.rol='cliente' and not p.suspendido and p.fecha_nacimiento is not null and (f.d-h)<=p_dias) x),'[]'::json); end $$;

revoke all on function _dar_cumple(uuid,boolean) from public,anon,authenticated;
notify pgrst, 'reload schema';
