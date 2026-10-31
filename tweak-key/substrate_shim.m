/* 免越狱 substrate 兼容层：只实现 Logos %hook 需要的 MSHookMessageEx。
 * 用 ObjC runtime，不需要任何越狱依赖。 */
#import "substrate.h"
#import <objc/runtime.h>
#include <stdbool.h>

void MSHookMessageEx(Class _class, SEL sel, IMP imp, IMP *result) {
    if (!_class || !sel || !imp) { if (result) *result = NULL; return; }
    Method m = class_getInstanceMethod(_class, sel);
    if (!m) { if (result) *result = NULL; return; }
    IMP old = method_setImplementation(m, imp);
    if (result) *result = old;
}

bool MSHookProcess(pid_t pid, const char *script) {
    (void)pid; (void)script;
    return false;   /* 不支持，仅占位 */
}
