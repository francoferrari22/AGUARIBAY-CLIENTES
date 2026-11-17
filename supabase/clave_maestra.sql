-- Contraseña de restauración (12345678): el personal se la da en mano al cliente que perdió la suya.
-- No reemplaza la contraseña elegida por cada cliente: solo sirve para que el cliente vuelva a entrar
-- y, apenas entra, se le obliga a elegir una nueva. No borra ni cambia nada más.
-- Ejecutar una sola vez en Supabase → SQL Editor. No borra datos existentes.

alter table profiles add column if not exists debe_cambiar_clave boolean default false;

create or replace function restablecer_clave(p_uid uuid) returns void language plpgsql security definer set search_path=public,extensions as $$
declare p profiles;
begin
  if not es_staff() then raise exception 'Solo el personal puede restablecer contraseñas.'; end if;
  select * into p from profiles where id=p_uid;
  if p.id is null or p.rol<>'cliente' then raise exception 'Solo se puede restablecer la contraseña de un cliente.'; end if;
  update auth.users set encrypted_password=extensions.crypt('12345678',extensions.gen_salt('bf')) where id=p_uid;
  update profiles set debe_cambiar_clave=true where id=p_uid;
  insert into auditoria(actor,accion,detalle) values(auth.uid(),'clave_restablecida',jsonb_build_object('cliente',p_uid,'email',p.email));
end $$;

-- El cliente no tiene permiso para tocar la columna debe_cambiar_clave directo (solo nombre/apellido/teléfono/foto),
-- así que usa esta función para avisar que ya eligió su contraseña nueva.
create or replace function confirmar_clave_cambiada() returns void language plpgsql security definer set search_path=public as $$
begin
  update profiles set debe_cambiar_clave=false where id=auth.uid();
end $$;
