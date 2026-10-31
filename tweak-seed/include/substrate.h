/* 最小 substrate 头：只为让 Logos 生成代码可编译。
 * 侧载（无越狱）场景下符号由 substrate_shim.m 提供，不依赖 CydiaSubstrate。 */
#ifndef REA_MIN_SUBSTRATE_H
#define REA_MIN_SUBSTRATE_H
#import <objc/runtime.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MSHookFunction_t)(void);
void MSHookMessageEx(Class _class, SEL sel, IMP imp, IMP *result);
bool MSHookProcess(pid_t pid, const char *script);

#ifdef __cplusplus
}
#endif
#endif
