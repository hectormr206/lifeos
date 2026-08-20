/// Lo primero que LifeOS le dice a alguien.
///
/// POR QUÉ ESTÁ EN UN ARCHIVO APARTE. Es la frase que más va a decidir si
/// alguien usa esto dos días o dos meses, y merece poder discutirse y probarse
/// sin abrir una pantalla.
///
/// LO QUE SE VEÍA ANTES. La primera pantalla de la app era "Permisos de
/// LifeOS" con una lista de casillas. Alguien que nunca ha oído hablar de esto
/// recibía un trámite antes que una razón: nada le decía qué es, para qué
/// sirve ni por qué debería contarle su vida a un axolote.
///
/// LAS REGLAS DE ESTE TEXTO:
///  * Dice lo que ES, no lo que no es. "No sube nada a la nube" explica una
///    ausencia; "se queda en este aparato" explica dónde está tu vida.
///  * Habla de la persona, no del producto. Ni arquitectura, ni modelos, ni
///    sincronización: eso ya se descubre solo cuando hace falta.
///  * Termina invitando a contar algo, no a leer más. Lo que engancha no es
///    entender la app: es ver qué hace con la primera cosa que le cuentas.
library;

/// Quién saluda. En primera persona: quien va a estar del otro lado es Axi.
const String kFirstDayGreeting = 'Hola, soy Axi.';

/// La frase. Una línea, y que se entienda de un vistazo.
const String kFirstDayPromise =
    'Cuéntame tu vida y yo me encargo de recordarla.';

/// Por qué se le puede contar algo a esto. Lo único técnico que se menciona el
/// primer día, porque es la diferencia real con todo lo demás que hay ahí
/// fuera — y porque es la razón por la que alguien se atreve a escribir de
/// verdad.
const String kFirstDayPrivacy =
    'Lo que me cuentes se queda en este aparato. El que te contesta soy yo, '
    'aquí dentro: no hay nadie del otro lado leyéndolo, y funciono aunque te '
    'quedes sin internet.';

/// La invitación. Ejemplos pequeños y cotidianos a propósito: quien no sabe
/// por dónde empezar no empieza, y "escribe tus metas" no lo hace nadie.
const String kFirstDayInvitation =
    'Empieza por cualquier cosa: cómo dormiste, con quién comiste, qué te dijo '
    'el doctor. De ahí voy sacando lo demás.';

/// Lo que dice el botón. Un verbo, y que se note quién hace qué.
const String kFirstDayCallToAction = 'Contarle algo a Axi';

/// Para quien prefiere mirar antes de escribir. Existe porque obligar a
/// alguien a escribir para entrar es la forma más rápida de que cierre la app.
const String kFirstDayLookAround = 'Prefiero mirar primero';
