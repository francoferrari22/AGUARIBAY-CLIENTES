-- Regla del regalo de cumpleaños (mínimo de visitas) + eliminar clientes. NO borra datos.
alter table config add column if not exists cumple_visitas_min int default 20;
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
  insert into notificaciones(user_id,titulo,cuerpo) values(p.id,'🎂 ¡Tenemos un regalo por tu cumpleaños!',pr.nombre||' · código '||cod);
 end if;
end loop; return n; end $$;

create or replace function mi_cumple() returns json language plpgsql security definer set search_path=public as $$
declare h date:=hoy_ar(); c config; p profiles; f date; n int; v12 int; begin
if auth.uid() is null then return null; end if;
select * into p from profiles where id=auth.uid(); select * into c from config where id=1;
if p.fecha_nacimiento is null then return json_build_object('nac',false); end if;
f:=case when cumple_en(p.fecha_nacimiento,extract(year from h)::int)>=h-c.cumple_dias_despues then cumple_en(p.fecha_nacimiento,extract(year from h)::int) else cumple_en(p.fecha_nacimiento,extract(year from h)::int+1) end;
n:=_dar_cumple(auth.uid(),false);
select count(*) into v12 from visitas where cliente_id=auth.uid() and estado='aprobada' and creada>=now()-interval '1 year';
return json_build_object('nac',true,'dias',f-h,'fecha',f,'nuevos',n,'vis',v12,'req',c.cumple_visitas_min,'apto',v12>=c.cumple_visitas_min); end $$;

create or replace function entregar_regalo_cumple(p_cliente uuid) returns int language plpgsql security definer set search_path=public as $$
declare n int; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
if (select count(*) from visitas where cliente_id=p_cliente and estado='aprobada' and creada>=now()-interval '1 year')<(select cumple_visitas_min from config where id=1) then raise exception 'El cliente no alcanza el mínimo de visitas aprobadas del último año para el regalo.'; end if;
n:=_dar_cumple(p_cliente,true);
insert into auditoria(actor,accion,detalle) values(auth.uid(),'regalo_cumple',jsonb_build_object('cliente',p_cliente,'entregados',n)); return n; end $$;

create or replace function cumples_proximos(p_dias int default 7) returns json language plpgsql security definer set search_path=public as $$
declare h date:=hoy_ar(); c config; begin
if not es_staff() then raise exception 'Sin permisos.'; end if;
select * into c from config where id=1;
return coalesce((select json_agg(x order by x.dias) from (
 select p.id,p.nombre,p.apellido,p.foto_url,p.telefono,f.d as fecha,(f.d-h) as dias,(extract(year from f.d)::int-extract(year from p.fecha_nacimiento)::int) as edad,
  exists(select 1 from canjes k join promociones pr on pr.id=k.promo_id where k.cliente_id=p.id and k.anio=extract(year from f.d)::int and pr.tipo='cumple') as regalo,(select count(*) from visitas v where v.cliente_id=p.id and v.estado='aprobada' and v.creada>=now()-interval '1 year') as vis,c.cumple_visitas_min as req
 from profiles p cross join lateral (select case when cumple_en(p.fecha_nacimiento,extract(year from h)::int)>=h-c.cumple_dias_despues then cumple_en(p.fecha_nacimiento,extract(year from h)::int) else cumple_en(p.fecha_nacimiento,extract(year from h)::int+1) end as d) f
 where p.rol='cliente' and not p.suspendido and p.fecha_nacimiento is not null and (f.d-h)<=p_dias) x),'[]'::json); end $$;

create or replace function eliminar_cliente(p_uid uuid) returns void language plpgsql security definer set search_path=public as $$
declare p profiles; begin
if not es_admin() then raise exception 'Solo el administrador puede eliminar clientes.'; end if;
select * into p from profiles where id=p_uid;
if p.id is null or p.rol<>'cliente' then raise exception 'Solo se pueden eliminar clientes.'; end if;
delete from notificaciones where user_id=p_uid; delete from mov_puntos where cliente_id=p_uid; delete from misiones_solicitudes where cliente_id=p_uid; delete from canjes where cliente_id=p_uid; delete from visitas where cliente_id=p_uid;
delete from profiles where id=p_uid;
delete from auth.users where id=p_uid;
insert into auditoria(actor,accion,detalle) values(auth.uid(),'cliente_eliminado',jsonb_build_object('email',p.email,'nombre',p.nombre,'apellido',p.apellido)); end $$;

revoke all on function _dar_cumple(uuid,boolean) from public,anon,authenticated;
notify pgrst, 'reload schema';
