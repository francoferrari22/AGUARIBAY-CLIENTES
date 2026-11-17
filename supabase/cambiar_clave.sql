-- Cambia la contraseña de los 3 administradores a 987654321 SIN borrar datos
update auth.users set encrypted_password=crypt('987654321',gen_salt('bf')) where email in ('admin@gmail.com','betsabe@gmail.com','aguaribay23@gmail.com');
