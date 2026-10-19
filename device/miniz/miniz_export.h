#ifndef MINIZ_EXPORT_H
#define MINIZ_EXPORT_H

#ifdef MINIZ_EXPORT
#error "MINIZ_EXPORT macro already defined"
#endif

#if defined(_WIN32) && !defined(MINIZ_DLL)
#define MINIZ_EXPORT
#elif defined(__GNUC__) && __GNUC__ >= 4 && !defined(MINIZ_DLL)
#define MINIZ_EXPORT __attribute__((visibility("default")))
#elif defined(MINIZ_DLL)
#if defined(MINIZ_NOT_STATIC_DLL)
#define MINIZ_EXPORT __declspec(dllexport)
#else
#define MINIZ_EXPORT __declspec(dllimport)
#endif
#else
#define MINIZ_EXPORT
#endif

#endif