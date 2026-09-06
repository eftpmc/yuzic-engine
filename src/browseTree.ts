import type { BrowseNode, Track } from './types';

/**
 * One node on the way across the bridge.
 *
 * Flat because a native `Record` cannot contain itself — Expo's `@Field` has
 * no way to describe recursion — so the tree travels as a list with parent
 * references and is rebuilt on the far side.
 *
 * This is a bridge artifact and nothing more. It is exported so it can be
 * tested, not so hosts have to think about it: `setBrowseTree` takes the
 * ordinary nested tree and flattens it here.
 */
export interface FlatBrowseNode {
  id: string;
  parentId?: string;
  title: string;
  subtitle?: string;
  artworkUri?: string;
  playable?: Track;
}

/**
 * Depth-first, parents before children, so the native side can rebuild in one
 * pass without buffering orphans.
 *
 * A node repeated under two parents keeps its first appearance. Ids are how a
 * selection is resolved, so the same id in two places would make a tap
 * ambiguous — better to drop the duplicate here, where it is a shallow bug,
 * than to have the car play something other than what it displayed.
 */
export function flattenBrowseTree(root: BrowseNode): FlatBrowseNode[] {
  const out: FlatBrowseNode[] = [];
  const seen = new Set<string>();

  const visit = (node: BrowseNode, parentId?: string) => {
    if (seen.has(node.id)) return;
    seen.add(node.id);
    out.push({
      id: node.id,
      parentId,
      title: node.title,
      subtitle: node.subtitle,
      artworkUri: node.artworkUri,
      playable: node.playable,
    });
    for (const child of node.children ?? []) visit(child, node.id);
  };

  // The root itself is not sent: the native side supplies its own container so
  // that an empty tree still has a title to show. Its children become the
  // top-level entries.
  for (const child of root.children ?? []) visit(child);
  return out;
}
