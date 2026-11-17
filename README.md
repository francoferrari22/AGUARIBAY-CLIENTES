# AGUARIBAY · Plataforma de fidelización

Frontend estático (GitHub Pages) + Supabase (Postgres, Auth, Storage privado, Realtime). Toda validación crítica corre en el servidor como funciones SQL `security definer` con RLS.

## Instalación
1. Supabase → SQL Editor → pegá **todo** `supabase/schema.sql` → Run. Crea todo y deja como administradores a admin@gmail.com, betsabe@gmail.com y aguaribay23@gmail.com (contraseña inicial 987654321; cambiala en Más → Mi cuenta).
2. Authentication → Sign In / Providers → Email → desactivá *Confirm email*.
3. `config.js` con tu Project URL y Publishable key.
4. Ingresá como administrador → Más → Ajustes → "Usar mi ubicación actual" estando en el local.

## Publicación
Ejecutá `SUBIR_A_GITHUB.bat` (sube a GitHub y el workflow `.github/workflows/pages.yml` publica solo). Una única vez: repo → Settings → Pages → Source = **GitHub Actions**.

## Flujos (sin códigos)
- **QR físico**: un QR (cualquier generador) que apunte a la URL de Pages, impreso en el local.
- **Visita**: el cliente toca "Registrar visita" → se comprueba su ubicación en ese momento → avisa su nombre al personal → el personal aprueba o rechaza (la solicitud vence a los 30 min y exige que el cliente haya estado dentro del radio).
- **Canje**: el cliente toca "Canjear ahora en caja" (se comprueba su ubicación) → al personal le llega un aviso (pantalla titila 10 s) → toca el aviso, confirma y aprueba.
- Los avisos funcionan con el panel abierto (no hay notificaciones push con la app cerrada).

## Seguridad
Claves públicas únicamente en el frontend; roles `cliente/staff/admin` verificados en servidor; puntos, aprobaciones y canjes solo modificables por funciones; auditoría en tabla `auditoria`. La geolocalización puede falsearse: por eso se combina con código de sesión, marcas de sospecha y aprobación humana. Activá **backups diarios** en Supabase (plan Pro) o exportá periódicamente.

## Cumpleaños y semana
- Instalación nueva: `schema.sql` ya lo incluye. Base existente: ejecutá `supabase/cumpleanos_semana.sql` (no borra datos).
- Regalo: Premios → ＋ → "Regalo de cumpleaños". Semana completa (lun–sáb): "Premio por completar la semana".
