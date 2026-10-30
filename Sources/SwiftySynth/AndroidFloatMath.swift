// Android's Swift SDK imports Bionic's libm as C functions only: unlike Darwin's overlay, it has no `Float` overloads
// of `cos`, `pow` and the rest, so the engine's `Float` math does not compile there. These forward to the `…f`
// functions Darwin's overloads call, so every platform computes the same values.
#if os(Android)
import Android

@inline(__always) func cos(_ x: Float) -> Float { cosf(x) }
@inline(__always) func sin(_ x: Float) -> Float { sinf(x) }
@inline(__always) func pow(_ x: Float, _ y: Float) -> Float { powf(x, y) }
@inline(__always) func log10(_ x: Float) -> Float { log10f(x) }
@inline(__always) func log(_ x: Float) -> Float { logf(x) }
@inline(__always) func exp(_ x: Float) -> Float { expf(x) }
#endif
