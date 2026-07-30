/**
 * circomlibjs ships no types. Only the Poseidon surface the mirror uses is declared,
 * deliberately narrow -- a broad `any` here would silently swallow a change in the
 * hasher's return shape, which is exactly the class of bug that makes on-chain and
 * in-circuit hashes diverge.
 */
declare module "circomlibjs" {
  export interface PoseidonField {
    toObject(value: unknown): bigint;
  }

  export interface Poseidon {
    (inputs: bigint[]): unknown;
    F: PoseidonField;
  }

  export function buildPoseidon(): Promise<Poseidon>;
}
