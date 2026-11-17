-- Permite borrar premios para siempre SIN perder datos (los canjes ya entregados se conservan)
alter table canjes drop constraint if exists canjes_promo_id_fkey;
alter table canjes add constraint canjes_promo_id_fkey foreign key(promo_id) references promociones(id) on delete set null;
notify pgrst, 'reload schema';
