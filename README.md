# Music Wallpaper

<img src="Resources/AppIcon.png" alt="Icono de Music Wallpaper" width="120">

Una aplicación personal para macOS que muestra la portada de la canción de Música o Spotify sobre el fondo de escritorio. La portada desaparece cuando ningún reproductor está activo o al salir de Music Wallpaper; el fondo original permanece intacto.

> Estado: prototipo de uso personal. Las portadas son estáticas; las animaciones de Apple Music y Spotify todavía no están implementadas.

## Requisitos

- Mac con macOS 14 o posterior. La aplicación se ha probado en macOS 27.0.1 con Apple Silicon; otras versiones y varios monitores requieren pruebas adicionales.
- Aplicación Música de macOS o Spotify para Mac y música con una portada accesible. Solo se observa la reproducción local en este Mac.
- Herramientas de línea de comandos de Xcode, con Swift y el SDK de macOS. No se necesita Xcode completo para compilar este proyecto.
- Acceso de **Automatización** a Música o Spotify cuando macOS lo solicite. Spotify necesita acceso a internet para descargar portadas.

## Instalación

Clona el repositorio y ejecuta el instalador desde Terminal:

```bash
git clone https://github.com/emmanu254/music-wallpaper.git
cd music-wallpaper
bash scripts/install.sh
```

El instalador compila y firma la app para uso local, la copia a `/Applications/Music Wallpaper.app` y solicita su registro como ítem de inicio de sesión. Necesitas permiso de escritura en `/Applications`. Si ya hay otra app con el mismo nombre y otro identificador, el instalador no la reemplaza.

1. Abre **Music Wallpaper** desde Aplicaciones.
2. Abre Música o Spotify y reproduce una canción.
3. Cuando macOS lo solicite, permite que Music Wallpaper automatice el reproductor correspondiente.
4. Busca el icono musical minimalista en la barra de menús.

La app se distribuye como código fuente: `build/` está excluido del repositorio. La firma es ad hoc y la app no está notarizada ni preparada para distribución pública.

## Uso

- **Cambiar de canción:** la portada se actualiza cuando el reproductor informa del cambio.
- **Pausar o cerrar un reproductor:** si el otro está reproduciendo, se utiliza su portada; si ninguno reproduce, desaparecen las capas y se ve el fondo anterior.
- **Usar ambos:** mientras la app está abierta, da prioridad al reproductor que informó más recientemente que comenzó a reproducir. Si ambos ya reproducían al abrir Music Wallpaper y aún no se ha recibido ningún aviso, consulta primero Música.
- **Actualizar ahora:** fuerza una nueva lectura desde el menú de la barra.
- **Abrir al iniciar sesión:** activa o desactiva el inicio automático desde ese mismo menú. También puedes gestionarlo en Ajustes del Sistema > General > Ítems de inicio. Si macOS solicita aprobación, habilita la app allí.
- **Salir:** cierra Music Wallpaper y retira sus capas. No cierra Música ni Spotify.

La app no cambia el fondo seleccionado en Ajustes del Sistema. Si una versión antigua dejó una portada como fondo real, selecciona otra vez el fondo que quieras desde Ajustes del Sistema > Fondo de pantalla.

## Cómo funciona

1. Music Wallpaper recibe avisos de reproducción de Música y Spotify y consulta sus diccionarios de AppleScript para leer el estado y los datos de la canción. Música proporciona la portada directamente; Spotify proporciona una URL de su CDN desde la que la app descarga la portada. Una consulta cada cinco segundos sirve de respaldo. La app no inicia los reproductores automáticamente.
2. La portada se muestra mediante ventanas de AppKit sin interacción, debajo de los iconos del escritorio. La imagen se ajusta para llenar la pantalla y puede recortarse.
3. Para que la portada acompañe la transición entre espacios, la app crea una capa por espacio y usa funciones privadas de WindowServer para asignarlas. Si una asignación falla temporalmente, conserva las demás y reintenta. Si la API privada no está disponible, utiliza una capa de AppKit que puede desaparecer durante el deslizamiento.
4. La portada se conserva en memoria para responder rápido al reanudar la misma canción. Las capas se eliminan al pausar o salir.

La integración privada con WindowServer puede dejar de funcionar tras una actualización de macOS. Las portadas de Spotify se descargan desde su CDN; la app no incluye envío de datos a servidores propios ni necesita contraseñas de Apple ID o Spotify.

## Solución de problemas

- **No aparece la portada:** comprueba que Música o Spotify esté abierto, reproduciendo y que la canción tenga portada. Consulta el mensaje en el menú de Music Wallpaper y prueba **Actualizar ahora**.
- **Permiso denegado:** ve a Ajustes del Sistema > Privacidad y seguridad > Automatización y permite el acceso de Music Wallpaper a Música o Spotify.
- **Portada de Spotify no carga:** comprueba la conexión a internet. Algunos contenidos pueden no ofrecer una URL de portada compatible.
- **La app no inicia con el Mac:** revisa **Abrir al iniciar sesión** en su menú y los ítems de inicio de macOS. La app arranca después de iniciar sesión en tu cuenta.
- **La portada desaparece al cambiar de espacio:** comprueba que la app siga abierta. La asignación por espacio depende de funciones no documentadas y puede variar entre versiones de macOS.
- **Fondo antiguo quedó aplicado por una versión anterior:** selecciónalo de nuevo en Ajustes del Sistema > Fondo de pantalla.

## Limitaciones

- No lee música que suene en el navegador, en otro reproductor o en otro dispositivo.
- Algunas canciones, pódcasts, transmisiones o archivos locales pueden no exponer una portada compatible.
- Las portadas animadas no están implementadas. Apple documenta cómo una app proporciona sus propios recursos animados al sistema, pero no se identificó una API pública para obtener los videos animados que usa Música.
- Se ha comprobado con una pantalla. Varias pantallas, Stage Manager y cambios futuros de macOS necesitan más pruebas.

## Estructura del proyecto

```text
Sources/MusicWallpaper.swift   Reproducción, menú y capas de escritorio
Sources/DesktopSpaces.swift    Asignación de ventanas a espacios
Resources/                     Icono de la app
scripts/build.sh               Compilación local del paquete .app
scripts/install.sh             Instalación y registro al iniciar sesión
```

Para compilar sin instalar:

```bash
bash scripts/build.sh
```

El resultado queda en `build/Music Wallpaper.app`.

## Referencias

- [Diccionarios de scripting de aplicaciones](https://support.apple.com/guide/script-editor/view-an-apps-scripting-dictionary-scpedt1126/mac)
- [MusicKit](https://developer.apple.com/documentation/musickit)
- [Portadas animadas para contenido multimedia](https://developer.apple.com/documentation/mediaplayer/providing-animated-artwork-for-media-items)
- [Notas del SDK de macOS 27](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
