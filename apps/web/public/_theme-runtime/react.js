// 主题运行时垫片：react（scripts/gen-theme-runtime.mjs 生成，勿手改）
const m = globalThis.__mcThemeRuntime?.modules?.["react"];
if (!m) throw new Error("主题运行时未就绪：react");
export default m.default ?? m;
export const { Activity, Children, Component, Fragment, Profiler, PureComponent, StrictMode, Suspense, act, cache, cacheSignal, captureOwnerStack, cloneElement, createContext, createElement, createRef, forwardRef, isValidElement, lazy, memo, startTransition, unstable_useCacheRefresh, use, useActionState, useCallback, useContext, useDebugValue, useDeferredValue, useEffect, useEffectEvent, useId, useImperativeHandle, useInsertionEffect, useLayoutEffect, useMemo, useOptimistic, useReducer, useRef, useState, useSyncExternalStore, useTransition, version } = m;
