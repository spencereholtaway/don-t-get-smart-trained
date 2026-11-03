// Turns decoded GTFS-realtime FeedMessages (toObject with longs as numbers) into the
// compact shape the map page reads. Shared by the Worker and scripts/build-data.mjs.
const r5 = (n) => Math.round(n * 1e5) / 1e5;

export function shapeTripUpdates(feed) {
  return {
    tripUpdates: (feed?.entity ?? []).filter((e) => e.tripUpdate?.trip?.tripId).map((e) => ({
      trip: e.tripUpdate.trip.tripId,
      startDate: e.tripUpdate.trip.startDate,
      vehicle: e.tripUpdate.vehicle?.id ?? null,
      stops: (e.tripUpdate.stopTimeUpdate ?? []).map((u) => [u.stopSequence, u.arrival?.time ?? null, u.departure?.time ?? null]),
    })),
    tripUpdatesAt: feed?.header?.timestamp ?? null,
  };
}

// Only vehicles assigned to a trip are trains in service; the rest are parked or trailing cars.
export function shapeVehicles(feed) {
  return {
    vehicles: (feed?.entity ?? []).filter((e) => e.vehicle?.trip?.tripId && e.vehicle.position).map((e) => ({
      id: e.vehicle.vehicle?.id ?? e.id,
      trip: e.vehicle.trip.tripId,
      lat: r5(e.vehicle.position.latitude), lon: r5(e.vehicle.position.longitude),
      bearing: e.vehicle.position.bearing ?? null,
      speed: e.vehicle.position.speed ?? null,
      status: e.vehicle.currentStatus ?? null,
      stopSeq: e.vehicle.currentStopSequence ?? null,
      at: e.vehicle.timestamp,
    })),
    vehiclesAt: feed?.header?.timestamp ?? null,
  };
}

export function shapeAlerts(feed) {
  return {
    alerts: (feed?.entity ?? []).filter((e) => e.alert).map((e) => ({
      id: e.id,
      header: e.alert.headerText?.translation?.[0]?.text ?? '',
      description: e.alert.descriptionText?.translation?.[0]?.text ?? '',
    })),
    alertsAt: feed?.header?.timestamp ?? null,
  };
}
