#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#include <stdint.h>
#include <dlfcn.h>

// IL2CPP runtime API types
typedef void* Il2CppDomain;
typedef void* Il2CppAssembly;
typedef void* Il2CppImage;
typedef void* Il2CppClass;
typedef void* Il2CppObject;
typedef void* MethodInfo;

// IL2CPP runtime function pointers
static Il2CppDomain* (*il2cpp_domain_get)(void);
static void** (*il2cpp_domain_get_assemblies)(Il2CppDomain* domain, size_t* size);
static Il2CppImage* (*il2cpp_assembly_get_image)(void* assembly);
static Il2CppClass* (*il2cpp_class_from_name)(Il2CppImage* image, const char* ns, const char* name);
static MethodInfo* (*il2cpp_class_get_method_from_name)(Il2CppClass* klass, const char* name, int argsCount);
static void* (*il2cpp_method_get_pointer)(MethodInfo* method);
static const char* (*il2cpp_image_get_name)(Il2CppImage* image);

// Dobby hook
extern void DobbyHook(void* target, void* replace, void** orig);

// Original function pointer
static bool (*orig_IsLocked)(Il2CppObject* self, MethodInfo* method);
static bool (*orig_IsBaseWeaponLocked)(Il2CppObject* self, MethodInfo* method);
static int  (*orig_GetLockState)(Il2CppObject* self, MethodInfo* method);

// Hook: always return false for IsLocked
static bool hook_IsLocked(Il2CppObject* self, MethodInfo* method) {
    return false;
}

static bool hook_IsBaseWeaponLocked(Il2CppObject* self, MethodInfo* method) {
    return false;
}

// Hook: always return 0 (unlocked) for lock state enum
static int hook_GetLockState(Il2CppObject* self, MethodInfo* method) {
    return 0;
}

static void setupHooks(void) {
    // Resolve IL2CPP exports from GameAssembly
    void* handle = dlopen("@rpath/GameAssembly.dylib", RTLD_NOLOAD | RTLD_NOW);
    if (!handle) handle = dlopen(NULL, RTLD_NOW); // fallback: search all

    #define RESOLVE(fn) fn = (typeof(fn))dlsym(handle, #fn); 
    RESOLVE(il2cpp_domain_get)
    RESOLVE(il2cpp_domain_get_assemblies)
    RESOLVE(il2cpp_assembly_get_image)
    RESOLVE(il2cpp_class_from_name)
    RESOLVE(il2cpp_class_get_method_from_name)
    RESOLVE(il2cpp_method_get_pointer)
    RESOLVE(il2cpp_image_get_name)

    if (!il2cpp_domain_get) return;

    Il2CppDomain* domain = il2cpp_domain_get();
    if (!domain) return;

    size_t count = 0;
    void** assemblies = il2cpp_domain_get_assemblies(domain, &count);
    if (!assemblies) return;

    // Search all images for our target classes
    for (size_t i = 0; i < count; i++) {
        Il2CppImage* img = il2cpp_assembly_get_image(assemblies[i]);
        if (!img) continue;

        // Try to find LoadoutItem class (contains bForceUnLock / bLockState)
        Il2CppClass* klass = il2cpp_class_from_name(img, "", "LoadoutItem");
        if (!klass) klass = il2cpp_class_from_name(img, "", "LoadoutItemAcquisitionComponent");
        if (!klass) continue;

        // Hook IsLocked / get_bLockState / get_bForceUnLock methods
        MethodInfo* mIsLocked = il2cpp_class_get_method_from_name(klass, "IsLocked", 0);
        if (mIsLocked) {
            void* ptr = il2cpp_method_get_pointer(mIsLocked);
            if (ptr) DobbyHook(ptr, (void*)hook_IsLocked, (void**)&orig_IsLocked);
        }

        MethodInfo* mLockState = il2cpp_class_get_method_from_name(klass, "GetLockState", 0);
        if (mLockState) {
            void* ptr = il2cpp_method_get_pointer(mLockState);
            if (ptr) DobbyHook(ptr, (void*)hook_GetLockState, (void**)&orig_GetLockState);
        }

        MethodInfo* mBaseLocked = il2cpp_class_get_method_from_name(klass, "IsBaseWeaponLocked", 0);
        if (mBaseLocked) {
            void* ptr = il2cpp_method_get_pointer(mBaseLocked);
            if (ptr) DobbyHook(ptr, (void*)hook_IsBaseWeaponLocked, (void**)&orig_IsBaseWeaponLocked);
        }
    }
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            setupHooks();
    });
}
