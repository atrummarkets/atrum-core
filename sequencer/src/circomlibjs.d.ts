/**
 * circomlibjs ships no types. Only the surfaces this package uses are declared,
 * deliberately narrow -- a broad `any` here would silently swallow a change in the
 * hasher's return shape, which is exactly the class of bug that makes on-chain and
 * in-circuit hashes diverge.
 *
 * The BabyJubJub surface is for the publisher's ElGamal decryption. Field elements are
 * left opaque on purpose: they are Montgomery-form internals, and the only legitimate way
 * to get a number out of one is `F.toObject`. Typing them as `unknown` makes an accidental
 * arithmetic or comparison on the raw representation a compile error rather than a wrong
 * decryption.
 */
declare module "circomlibjs" {
  /** Opaque field element. Never operate on this directly -- go through `BabyJubField`. */
  export type FieldElement = unknown;
  export type CurvePoint = FieldElement[];

  export interface BabyJubField {
    e(value: bigint | number): FieldElement;
    neg(value: FieldElement): FieldElement;
    eq(a: FieldElement, b: FieldElement): boolean;
    toObject(value: FieldElement): bigint;
  }

  export interface BabyJub {
    F: BabyJubField;
    Base8: CurvePoint;
    addPoint(a: CurvePoint, b: CurvePoint): CurvePoint;
    mulPointEscalar(point: CurvePoint, scalar: bigint): CurvePoint;
  }

  export function buildBabyjub(): Promise<BabyJub>;

  export interface PoseidonField {
    toObject(value: unknown): bigint;
  }

  export interface Poseidon {
    (inputs: bigint[]): unknown;
    F: PoseidonField;
  }

  export function buildPoseidon(): Promise<Poseidon>;
}
