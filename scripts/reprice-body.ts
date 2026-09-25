/** Every page of a paginated collection. */
export async function pageAll(
  api: (method: string, endpoint: string, body?: unknown) => Promise<any>,
  endpoint: string,
): Promise<any[]> {
  const out: any[] = [];
  let next: string | null = endpoint;
  while (next) {
    const page: any = await api("GET", next);
    out.push(...(page.data ?? []));
    const link: string | undefined = page.links?.next;
    next = link ? link.replace("https://api.appstoreconnect.apple.com", "") : null;
  }
  return out;
}

export interface Plan {
  id: string;
  productId: string;
  usd: number;
}

/**
 * Sets every storefront to the rung that reads exactly the target price.
 *
 * The prices were never set at all: the original `create-subscriptions.ts`
 * POST is wrapped in a `.catch` that logs "PRICE REFUSED (Paid Apps
 * Agreement?)" and carries on, and that is what happened — the USA row is
 * still unset today. Apple filled the gap with its own defaults, which is why
 * 89 territories read 29.99 and 46 read 34.99 for the same product.
 *
 * So this is not a conversion problem and there is no exchange rate to guess
 * at. It is 46 storefronts that were never told the price. Each territory's
 * own ladder is read and the rung whose customer price is literally the
 * target is chosen — the same number the app advertises, in that storefront's
 * own currency.
 *
 * Territories with no such rung are named rather than rounded to, because
 * "close enough" on somebody's card is not mine to decide.
 */
export async function reprice(
  api: (method: string, endpoint: string, body?: unknown) => Promise<any>,
  plans: Plan[],
  apply: boolean,
): Promise<void> {
  const territories = (await pageAll(api, "/v1/territories?limit=200")).map((t: any) => t.id);
  console.log(`${territories.length} territories on the account`);

  for (const plan of plans) {
    const target = plan.usd.toFixed(2);
    console.log(`\n=== ${plan.productId} — every storefront to ${target}`);

    const now = await api(
      "GET",
      `/v1/subscriptions/${plan.id}/prices?include=subscriptionPricePoint&limit=200`,
    );
    const included: Record<string, any> = Object.fromEntries(
      (now.included ?? []).map((i: any) => [i.id, i]),
    );
    const current = new Map<string, string>();
    for (const row of now.data ?? []) {
      const territory = row.relationships?.territory?.data?.id;
      const price = included[row.relationships?.subscriptionPricePoint?.data?.id]
        ?.attributes?.customerPrice;
      if (territory && price) current.set(territory, price);
    }

    const wrong = territories.filter((t: string) => current.get(t) !== target);
    console.log(`  ${territories.length - wrong.length} already at ${target}, ${wrong.length} are not`);

    let set = 0;
    const noRung: string[] = [];
    const refused: string[] = [];

    for (const territory of wrong) {
      let rung: any;
      try {
        const ladder = await pageAll(
          api,
          `/v1/subscriptions/${plan.id}/pricePoints?filter[territory]=${territory}&limit=200`,
        );
        rung = ladder.find((p: any) => p.attributes.customerPrice === target);
      } catch (thrown) {
        refused.push(`${territory}: ${String(thrown).slice(0, 80)}`);
        continue;
      }

      if (!rung) {
        noRung.push(`${territory} (is ${current.get(territory) ?? "unset"})`);
        continue;
      }
      if (!apply) {
        set++;
        continue;
      }

      try {
        // `preserveCurrentPrice: false` is the point. Preserving it is right
        // for a price RISE, so existing subscribers keep what they agreed to.
        // Here the whole job is to correct a price nobody agreed to.
        await api("POST", "/v1/subscriptionPrices", {
          data: {
            type: "subscriptionPrices",
            attributes: { preserveCurrentPrice: false },
            relationships: {
              subscription: { data: { type: "subscriptions", id: plan.id } },
              subscriptionPricePoint: {
                data: { type: "subscriptionPricePoints", id: rung.id },
              },
            },
          },
        });
        set++;
      } catch (thrown) {
        refused.push(`${territory}: ${String(thrown).slice(0, 80)}`);
      }
    }

    console.log(`  ${apply ? "set" : "would set"} ${set}`);
    if (noRung.length) {
      console.log(`  ⚠ ${noRung.length} storefronts have no ${target} rung:`);
      console.log("     " + noRung.slice(0, 25).join(", "));
      if (noRung.length > 25) console.log(`     …and ${noRung.length - 25} more`);
    }
    if (refused.length) {
      console.log(`  ⚠ ${refused.length} refused. First few:`);
      for (const r of refused.slice(0, 3)) console.log("     " + r);
    }
  }

  console.log(apply ? "\nDone." : "\nReport only. Pass --apply to set these.");
}
