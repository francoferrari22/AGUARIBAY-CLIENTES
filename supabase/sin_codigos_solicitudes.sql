-- Sin códigos: visitas y canjes se aprueban desde el panel. NO borra datos.
alter table canjes add column if not exists solicitado_en timestamptz;
alter table canjes drop constraint if exists canjes_estado_check;
alter table canjes add constraint canjes_estado_check check(estado in('pendiente','solicitado','canjeado'));
drop function if exists solicitar_visita(float8,float8,text);
drop function if exists validar_canje(text);
create or replace function solicitar_visita(p_lat float8,p_lng float8) returns uuid language plpgsql security definer set search_path=public as $$
declare c config; d float8; v_id uuid; sus boolean; begin
if auth.uid() is null or (select suspendido from profiles where id=auth.uid()) then raise exception 'Cuenta no habilitada.'; end if;
select * into c from config where id=1;
d:=distancia_m(p_lat,p_lng,c.lat,c.lng);
if d>c.radio_m then raise exception 'Para registrar tu visita, necesitás estar en AGUARIBAY.'; end if;
update visitas set estado='rechazada',motivo_rechazo='Venció sin aprobación',revisada_en=now() where cliente_id=auth.uid() and estado='pendiente' and creada<now()-interval '30 minutes';
if exists(select 1 from visitas where cliente_id=auth.uid() and (estado='pendiente' or (estado='aprobada' and creada>now()-c.horas_min*interval '1 hour'))) then raise exception 'Ya tenés una visita pendiente o reciente.'; end if;
sus:= d<0.5 or exists(select 1 from visitas where lat=p_lat and lng=p_lng and cliente_id<>auth.uid() and creada>now()-interval '1 day');
insert into visitas(cliente_id,lat,lng,distancia_m,sospechosa) values(auth.uid(),p_lat,p_lng,d,sus) returning id into v_id; return v_id; end $$;

create or replace function resolver_visita(p_id uuid,p_ok boolean,p_motivo text default null) returns void language plpgsql security definer set search_path=public as $$
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
insert into notificaciones(user_id,titulo,cuerpo) values(pr.id,'¡Premio desbloqueado!',p.nombre||' · ya está disponible en Tus premios');
return cod; end $$;

create or replace function _dar_cumple(p_uid uuid,p_force boolean) returns int language plpgsql security definer set search_path=public as $$
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

create or replace function solicitar_canje(p_id uuid,p_lat float8,p_lng float8) returns void language plpgsql security definer set search_path=public as $$
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

create or replace function resolver_canje(p_id uuid,p_ok boolean,p_motivo text default null) returns void language plpgsql security definer set search_path=public as $$
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

create or replace function stats() returns json language sql security definer set search_path=public as $$
select json_build_object('clientes',(select count(*) from profiles where rol='cliente'),'visitas_hoy',(select count(*) from visitas where creada::date=current_date),'pendientes',(select count(*) from visitas where estado='pendiente'),'aprobadas',(select count(*) from visitas where estado='aprobada'),'canjes',(select count(*) from canjes where estado='canjeado'),'canjes_sol',(select count(*) from canjes where estado='solicitado'),'promos',(select count(*) from promociones where activa)) where es_staff() $$;

revoke all on function _dar_cumple(uuid,boolean) from public,anon,authenticated;
do $$ begin alter publication supabase_realtime add table canjes; exception when others then null; end $$;
notify pgrst, 'reload schema';
