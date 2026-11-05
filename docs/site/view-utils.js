export function paginate(items, requestedPage = 1, pageSize = 5) {
  const size = [5, 10, 25].includes(pageSize) ? pageSize : 5;
  const pages = Math.max(1, Math.ceil(items.length / size));
  const page = Math.max(1, Math.min(pages, Math.trunc(requestedPage) || 1));
  const start = (page - 1) * size;
  return {
    items: items.slice(start, start + size),
    page,
    pages,
    total: items.length,
    start: items.length ? start + 1 : 0,
    end: Math.min(start + size, items.length),
  };
}
export function statusCounts(requests) {
  return ["Pending", "Issued", "Rejected", "Cancelled"].map((status) => ({
    status,
    count: requests.filter((request) => request.status === status).length,
  }));
}
export function stockParts(onHand, free) {
  const available = Math.max(0, Math.min(onHand, free));
  return {
    available,
    reserved: Math.max(0, onHand - available),
    onHand,
    percent: onHand > 0 ? (available / onHand) * 100 : 0,
  };
}
