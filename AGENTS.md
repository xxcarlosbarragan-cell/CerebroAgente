# CEREBRO AGENT — PROTOCOLO PARA ACTUALIZAR DESDE CUALQUIER CHAT

**Repositorio:** https://github.com/xxcarlosbarragan-cell/CerebroAgente
**Rama de trabajo actual:** `cerebro-agent-portable-preparacion`
**Rama de publicación OTA:** `main` (NO modificar sin autorización específica del usuario).
**Rama de referencia:** `cerebro-agent-v2.3`.

## Instrucción para cualquier chat conectado a GitHub

Si el usuario dice "Actualiza Cerebro Agent: [cambio]", consulta primero este documento y los archivos actuales de la rama de trabajo, realiza el cambio solicitado **directamente en la rama** usando la conexión GitHub y verifica el resultado. No pidas un ZIP ni que edite fragmentos de código cuando el repositorio sea accesible. Enviar instrucciones desde un chat no programa ni ejecuta actualizaciones por sí solo: el usuario debe enviar el mensaje y tener la conexión GitHub habilitada.

## Flujo obligatorio

1. Leer la rama `cerebro-agent-portable-preparacion`, las versiones y la última solicitud de cambios.
2. Preservar funciones anteriores y revisar dependencias, consumo de RAM, HDD y CPU.
3. Modificar solo la rama de trabajo; crear commit con descripción concreta.
4. Verificar archivos modificados, JavaScript y, cuando sea posible, PowerShell; distinguir pruebas estáticas de pruebas reales en Windows.
5. Entregar informe **muy corto**: cambio hecho, qué se verificó, enlace a GitHub y si se necesita intervención manual.
6. Para pruebas en HP 240 G8, solicitar autorización explícita antes de cualquier instalación o de fusionar con `main`.
7. **Prohibido:** publicar en `main` o activar OTA sin autorización, añadir programas de inicio automático, desactivar Defender, borrar archivos, simular lecturas de disco, instalar servicios o pedir privilegios de administrador sin justificación.

## Arquitectura e invariantes

Los cuatro archivos de ejecución continúan en la raíz:
- `Iniciar_Cerebro_Agent.cmd`
- `CerebroAgent.ps1`
- `interfaz.html`
- `version.txt`

Se permiten documentos de mantenimiento en `.github/` y `AGENTS.md`; no añadas dependencias de ejecución ni paquetes innecesarios. Servidor local `http://localhost:5050`, endpoint `/api/data`, codificación UTF-8. Respetar las URLs existentes de GitHub. Consultas de CPU/RAM de bajo impacto; evitar `Win32_PerfFormattedData_PerfDisk_PhysicalDisk`.

## Modo Portable (objetivo aprobado)

- Arranque **manual** desde USB, sin autorun ni inicio con Windows.
- No asumir que retirar la USB mata procesos: cerrar servidor explícitamente y avisar para expulsión segura.
- Modo ligero predeterminado; animaciones 3D opcionales. No confundir avatares decorativos con agentes independientes.
- No iniciar actualizaciones OTA automáticas hasta revisar el mecanismo y obtener autorización de publicación.
- Mantener una opción de **prueba local** supervisada, sin instalar ni modificar Windows.

## Mensaje de activación reutilizable

"**Actualiza Cerebro Agent** en el repositorio `xxcarlosbarragan-cell/CerebroAgente`, rama `cerebro-agent-portable-preparacion`. Lee el archivo `AGENTS.md` de esa rama y ejecuta mi cambio: [descripción]. Deja los cambios en pruebas, NO modifiques `main`. Muéstrame un informe corto y solo pide intervención manual si es indispensable."

## Control de publicación

Una rama de GitHub y una solicitud de extracción (PR) no instalan nada en la laptop. El usuario debe autorizar explícitamente la publicación en `main` y la aplicación de una versión OTA. Cuando el usuario confirme una USB, probar consumo, apagado y compatibilidad en el equipo antes de activar.
