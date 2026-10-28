// Stripe is not connected. This endpoint refuses events until the owner adds Stripe.
// Do not treat a response from this function as a captured charge.

Deno.serve(async () => {
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? ""
  if (!secret) {
    return Response.json(
      { error: "Stripe is not configured. No charge, capture, or payout was recorded." },
      { status: 501 },
    )
  }
  return Response.json(
    { error: "Webhook signature checks are not implemented yet. No payout was sent." },
    { status: 501 },
  )
})
