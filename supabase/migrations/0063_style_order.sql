-- The styles people actually pick, first.
--
-- Abel, 24 Sep 2026: "make the most selected on the first place and the most
-- important on the first places. And the unwanted are the last."
--
-- `sort` was grouped by category, so the grid opened on Stories whatever the
-- account was. It now opens on what a new account is most likely to want and
-- most likely to keep: broad, daily-sustainable styles that need no footage of
-- their own, then the specialist ones, then the styles that need a real
-- subject in front of a real camera -- which an automated series is worst at.
--
-- This is a starting order, not a verdict. Once enough plans exist it should
-- be replaced by what people actually chose; see `style_pick_counts` below.
update public.content_templates set sort = case slug
  -- Anyone can run these on day one, they never run out of material, and the
  -- generator can make every shot.
  when 'facts'        then 10
  when 'tips'         then 20
  when 'explainer'    then 30
  when 'product'      then 40
  when 'myths'        then 50
  when 'storytime'    then 60
  when 'scary'        then 70
  when 'compare'      then 80
  when 'motivation'   then 90
  when 'aitools'      then 100
  when 'quotes'       then 110
  when 'productivity' then 120

  -- Strong, but they need a subject: a niche, a product line, a place.
  when 'marketing'    then 130
  when 'finance'      then 140
  when 'apps'         then 150
  when 'sidehustle'   then 160
  when 'history'      then 170
  when 'mystery'      then 180
  when 'nutrition'    then 190
  when 'fitness'      then 200
  when 'sleep'        then 210
  when 'language'     then 220
  when 'ecommerce'    then 230
  when 'trends'       then 240

  -- Good styles that lean on footage, a face or a life to film.
  when 'founder'      then 250
  when 'dayinlife'    then 260
  when 'travel'       then 270
  when 'food'         then 280
  when 'pets'         then 290
  when 'luxury'       then 300
  when 'satisfying'   then 310
  when 'pov'          then 320
  when 'reactions'    then 330
  when 'gadgets'      then 340
  when 'process'      then 350
  when 'photography'  then 360
  else sort
end
where enabled;

-- What people actually picked, so the order above can stop being a guess.
--
-- Counted from plans rather than from taps: choosing a style in the flow and
-- then abandoning it is not a preference, and a plan that was actually started
-- is. Read by nothing yet -- it is here so the number exists to look at before
-- anybody argues about the order again.
create or replace view public.style_pick_counts as
  select t.slug,
         t.name,
         t.sort,
         count(p.id) as plans_started
    from public.content_templates t
    left join public.content_plans p on p.template_slug = t.slug
   where t.enabled
   group by t.slug, t.name, t.sort
   order by plans_started desc, t.sort;

revoke all on public.style_pick_counts from anon, authenticated;
