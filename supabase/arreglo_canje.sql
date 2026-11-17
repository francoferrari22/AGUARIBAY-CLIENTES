-- Arreglo SIN borrar datos: corrige 'gen_random_bytes does not exist' al canjear premios / aprobar visitas
create or replace function resolver_visita(p_id uuid,p_ok boolean,p_motivo text default null) returns void language plpgsql security definer set search_path=public as $$
declare v visitas; c config; nv int; pr promociones; cod text; begin
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
 end loop; end if;
insert into notificaciones(user_id,titulo,cuerpo) values(v.cliente_id,case when p_ok then '¡Visita aprobada!' else 'Visita rechazada' end,case when p_ok then 'Sumaste un sello y '||c.puntos_visita||' puntos.' else coalesce(p_motivo,'Consultá con el personal.') end);
insert into auditoria(actor,accion,detalle) values(auth.uid(),case when p_ok then 'visita_aprobada' else 'visita_rechazada' end,jsonb_build_object('id',p_id,'motivo',p_motivo)); end $$;

create or replace function reclamar_premio(p_id uuid) returns text language plpgsql security definer set search_path=public as $$
declare p promociones; pr profiles; cod text; n int; begin
select * into pr from profiles where id=auth.uid() for update;
if pr.suspendido then raise exception 'Cuenta suspendida.'; end if;
select * into p from promociones where id=p_id for update;
if p.id is null or not p.activa or p.inicio>now() or p.fin<now() then raise exception 'Premio no disponible.'; end if;
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

notify pgrst, 'reload schema';
