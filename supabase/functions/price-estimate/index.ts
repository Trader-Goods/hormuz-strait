// Rule-based price estimate. No AI key. Keep the numbers aligned with Contractor/PricingRates.json.
// A photo model can replace the body of this function later. It must return questions instead of inventing a measurement.

const disclaimer = "Default regional rates are editable configuration. They are not a survey of local prices, and photos are not used to measure the job."

const rates: Record<string, { small: number; medium: number; large: number; smallMin: number; mediumMin: number; largeMin: number; obstacle: number; obstacleMin: number }> = {
  mowing: { small: 5500, medium: 8500, large: 13000, smallMin: 45, mediumMin: 60, largeMin: 90, obstacle: 1500, obstacleMin: 15 },
  edging: { small: 3500, medium: 5000, large: 7500, smallMin: 30, mediumMin: 40, largeMin: 55, obstacle: 1000, obstacleMin: 10 },
  trimming: { small: 4500, medium: 7000, large: 11000, smallMin: 40, mediumMin: 55, largeMin: 80, obstacle: 2000, obstacleMin: 20 },
  leafCleanup: { small: 6000, medium: 9500, large: 15000, smallMin: 50, mediumMin: 75, largeMin: 110, obstacle: 2000, obstacleMin: 20 },
  landscaping: { small: 12000, medium: 20000, large: 35000, smallMin: 90, mediumMin: 150, largeMin: 240, obstacle: 4000, obstacleMin: 30 },
  yardOther: { small: 5000, medium: 8000, large: 12000, smallMin: 45, mediumMin: 60, largeMin: 90, obstacle: 1500, obstacleMin: 15 },
  moving: { small: 18000, medium: 32000, large: 48000, smallMin: 120, mediumMin: 210, largeMin: 300, obstacle: 5000, obstacleMin: 30 },
}

const yard = new Set(["mowing", "edging", "trimming", "leafCleanup", "landscaping", "yardOther"])

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return Response.json({ error: "POST a pricing request" }, { status: 405 })
  }
  const body = await request.json().catch(() => ({}))
  const serviceType = String(body.serviceType ?? "")
  const yardSize = String(body.yardSize ?? "")
  const lotSize = String(body.lotSize ?? "").trim()
  const rooms = Number(body.rooms ?? 0)
  const obstacles = String(body.obstacles ?? "").trim()
  const details = String(body.details ?? "").trim()
  const photoCount = Number(body.photoCount ?? 0)
  const zip = String(body.zip ?? "")
  const questions: string[] = []
  const rate = rates[serviceType]
  if (!rate) questions.push("Which service do you need?")
  if (yard.has(serviceType) && (yardSize === "" || yardSize === "Unknown") && lotSize === "") {
    questions.push("About how big is the yard, or what is the lot size?")
  }
  if (serviceType === "moving" && rooms < 1) questions.push("How many rooms are moving?")
  if (details.length < 8 && obstacles === "") {
    questions.push("Add a short instruction or name any obstacles, such as a slope, pets, a gate, or stairs.")
  }
  if (questions.length || !rate) {
    return Response.json({
      questions: questions.length ? questions : ["Add a little more detail and estimate again."],
      suggestedCents: null,
      isGuaranteedQuote: false,
      disclaimer,
      rateName: "US default",
      explanation: "No price yet. Answer the questions above. The estimator will not guess.",
    })
  }
  let size: "small" | "medium" | "large" = "medium"
  if (serviceType === "moving") size = rooms <= 2 ? "small" : rooms <= 4 ? "medium" : "large"
  else if (yardSize === "Small") size = "small"
  else if (yardSize === "Large") size = "large"
  let cents = rate[size]
  let minutes = size === "small" ? rate.smallMin : size === "large" ? rate.largeMin : rate.mediumMin
  if (obstacles) {
    cents += rate.obstacle
    minutes += rate.obstacleMin
  }
  return Response.json({
    questions: [],
    lowCents: Math.floor(cents * 80 / 100),
    highCents: Math.floor(cents * 120 / 100),
    suggestedCents: cents,
    estimatedMinutes: minutes,
    rateName: "US default",
    disclaimer,
    isGuaranteedQuote: false,
    explanation: `Estimate ${cents} cents from the US default rate card. This is an estimate, not a guaranteed quote. ZIP ${zip || "unknown"} does not change the card.`,
    assumptions: [
      photoCount > 0 ? `${photoCount} photos are not measured.` : "No photos were measured.",
      "The rate card is editable configuration, not live market data.",
    ],
  })
})
