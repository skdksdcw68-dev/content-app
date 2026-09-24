-- The order the styles are offered in, from the producer's two rankings.
--
-- 0063 ordered them by my own judgement. This replaces that with the two
-- rankings that came back with the workflows (24 Sep 2026): how likely a new
-- account is to PICK a style, and how well it SURVIVES a month of daily
-- automated posting. The order is both added together, because a style
-- somebody loves on day one and abandons in week two is a bad first tile.
--
-- Top: Tips, Did you know, AI tools, Quotes -- near-unlimited material, every
-- shot machine-made. Bottom: POV, Satisfying and Marketing lessons, which are
-- visually narrow or need a fresh real example every day, and go stale fastest
-- under automation.
update public.content_templates set sort = case slug
  when 'tips' then 10
  when 'facts' then 20
  when 'aitools' then 30
  when 'quotes' then 40
  when 'scary' then 50
  when 'finance' then 60
  when 'product' then 70
  when 'myths' then 80
  when 'productivity' then 90
  when 'explainer' then 100
  when 'food' then 110
  when 'storytime' then 120
  when 'fitness' then 130
  when 'motivation' then 140
  when 'apps' then 150
  when 'language' then 160
  when 'gadgets' then 170
  when 'pets' then 180
  when 'nutrition' then 190
  when 'compare' then 200
  when 'travel' then 210
  when 'ecommerce' then 220
  when 'trends' then 230
  when 'history' then 240
  when 'mystery' then 250
  when 'sidehustle' then 260
  when 'process' then 270
  when 'luxury' then 280
  when 'founder' then 290
  when 'dayinlife' then 300
  when 'reactions' then 310
  when 'sleep' then 320
  when 'satisfying' then 330
  when 'photography' then 340
  when 'pov' then 350
  when 'marketing' then 360
  else sort
end
where enabled;
