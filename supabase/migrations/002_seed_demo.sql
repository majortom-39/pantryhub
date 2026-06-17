-- Seed: demo user + 42 pantry items mirroring PantryHub/SampleData.swift.
-- Idempotent: re-runnable. Uses fixed demo UUID so we can reference it everywhere.

INSERT INTO app_users (id, external_id, display_name)
VALUES ('00000000-0000-0000-0000-000000000001', 'demo', 'Alex')
ON CONFLICT (id) DO NOTHING;

-- Clear and reseed pantry for the demo user (so re-running this is safe).
DELETE FROM pantry_items WHERE user_id = '00000000-0000-0000-0000-000000000001';

INSERT INTO pantry_items
  (user_id, name, brand, image_name, image_kind, category, quantity, fullness_levels, fullness_unit, expiry)
VALUES
  -- Grains & Bread
  ('00000000-0000-0000-0000-000000000001', 'Corn Flakes',       'Kellogg''s',    'prod-cornflakes', 'product', 'grains',     '500 g box',  ARRAY[0.4, 0.15], 'g',  CURRENT_DATE + 40),
  ('00000000-0000-0000-0000-000000000001', 'Spaghetti',          'Barilla',      'prod-spaghetti',  'product', 'grains',     '500 g box',  ARRAY[1.0],       '%',  CURRENT_DATE + 200),
  ('00000000-0000-0000-0000-000000000001', 'Whole Wheat Bread',  'Harvest Gold', 'prod-bread',      'product', 'grains',     '400 g loaf', ARRAY[0.6],       '%',  CURRENT_DATE + 3),
  ('00000000-0000-0000-0000-000000000001', 'All-Purpose Flour',  'Gold Medal',   'prod-flour',      'product', 'grains',     '1 kg bag',   ARRAY[0.8],       'g',  CURRENT_DATE + 150),

  -- Dairy & Eggs
  ('00000000-0000-0000-0000-000000000001', 'Eggs',           '',         '',             'generic', 'dairy',  '6 pcs',         ARRAY[0.66], '%',  CURRENT_DATE + 9),
  ('00000000-0000-0000-0000-000000000001', 'Milk',           'Amul',     '',             'generic', 'dairy',  '1 L carton',    ARRAY[0.5],  'ml', CURRENT_DATE + 4),
  ('00000000-0000-0000-0000-000000000001', 'Butter',         'Amul',     '',             'generic', 'dairy',  '200 g',         ARRAY[0.3],  '%',  CURRENT_DATE + 25),
  ('00000000-0000-0000-0000-000000000001', 'Greek Yogurt',   'Chobani',  'prod-yogurt',  'product', 'dairy',  '750 g tub',     ARRAY[0.8],  '%',  CURRENT_DATE + 6),
  ('00000000-0000-0000-0000-000000000001', 'Cheddar Cheese', 'Cabot',    'prod-cheddar', 'product', 'dairy',  '250 g block',   ARRAY[0.5],  '%',  CURRENT_DATE + 18),
  ('00000000-0000-0000-0000-000000000001', 'Parmesan',       '',         '',             'generic', 'dairy',  '100 g wedge',   ARRAY[0.3],  '%',  CURRENT_DATE + 14),

  -- Fruits & Veg
  ('00000000-0000-0000-0000-000000000001', 'Tomatoes',     '', '', 'generic', 'produce', '6 pcs',    ARRAY[0.7],  '%', CURRENT_DATE + 10),
  ('00000000-0000-0000-0000-000000000001', 'Onion',        '', '', 'generic', 'produce', '4 pcs',    ARRAY[0.6],  '%', CURRENT_DATE + 30),
  ('00000000-0000-0000-0000-000000000001', 'Garlic',       '', '', 'generic', 'produce', '1 bulb',   ARRAY[0.55], '%', CURRENT_DATE + 45),
  ('00000000-0000-0000-0000-000000000001', 'Spinach',      '', '', 'generic', 'produce', '1 bunch',  ARRAY[0.45], '%', CURRENT_DATE + 2),
  ('00000000-0000-0000-0000-000000000001', 'Lemon',        '', '', 'generic', 'produce', '3 pcs',    ARRAY[0.8],  '%', CURRENT_DATE + 12),
  ('00000000-0000-0000-0000-000000000001', 'Carrots',      '', '', 'generic', 'produce', '500 g',    ARRAY[0.7],  '%', CURRENT_DATE + 20),
  ('00000000-0000-0000-0000-000000000001', 'Potatoes',     '', '', 'generic', 'produce', '1 kg',     ARRAY[0.8],  '%', CURRENT_DATE + 35),
  ('00000000-0000-0000-0000-000000000001', 'Bell Pepper',  '', '', 'generic', 'produce', '3 pcs',    ARRAY[0.6],  '%', CURRENT_DATE + 14),
  ('00000000-0000-0000-0000-000000000001', 'Broccoli',     '', '', 'generic', 'produce', '1 head',   ARRAY[0.5],  '%', CURRENT_DATE + 9),
  ('00000000-0000-0000-0000-000000000001', 'Mushrooms',    '', '', 'generic', 'produce', '250 g',    ARRAY[0.65], '%', CURRENT_DATE + 5),
  ('00000000-0000-0000-0000-000000000001', 'Avocado',      '', '', 'generic', 'produce', '2 pcs',    ARRAY[1.0],  '%', CURRENT_DATE + 4),

  -- Meat & Seafood
  ('00000000-0000-0000-0000-000000000001', 'Chicken Breast', '', '', 'generic', 'meat', '400 g',     ARRAY[1.0], '%', CURRENT_DATE + 9),
  ('00000000-0000-0000-0000-000000000001', 'Ground Beef',    '', '', 'generic', 'meat', '500 g',     ARRAY[1.0], '%', CURRENT_DATE + 8),
  ('00000000-0000-0000-0000-000000000001', 'Bacon',          '', '', 'generic', 'meat', '250 g pack', ARRAY[0.8], '%', CURRENT_DATE + 12),
  ('00000000-0000-0000-0000-000000000001', 'Salmon Fillet',  '', '', 'generic', 'meat', '2 fillets', ARRAY[1.0], '%', CURRENT_DATE + 5),
  ('00000000-0000-0000-0000-000000000001', 'Shrimp',         '', '', 'generic', 'meat', '300 g',     ARRAY[1.0], '%', CURRENT_DATE + 8),
  ('00000000-0000-0000-0000-000000000001', 'Pork Chops',     '', '', 'generic', 'meat', '4 pcs',     ARRAY[1.0], '%', CURRENT_DATE + 6),

  -- Condiments & Spices
  ('00000000-0000-0000-0000-000000000001', 'Olive Oil',         'Bertolli',         'prod-oliveoil', 'product', 'condiments', '500 ml',     ARRAY[0.65], 'ml', CURRENT_DATE + 120),
  ('00000000-0000-0000-0000-000000000001', 'Honey',             'Nature Nate''s',   'prod-honey',    'product', 'condiments', '340 g jar',  ARRAY[0.9],  '%',  CURRENT_DATE + 300),
  ('00000000-0000-0000-0000-000000000001', 'Cinnamon',          'McCormick',        'prod-cinnamon', 'product', 'condiments', '50 g jar',   ARRAY[0.7],  '%',  CURRENT_DATE + 220),
  ('00000000-0000-0000-0000-000000000001', 'Salt',              '', '', 'generic', 'condiments', '1 kg',  ARRAY[0.85], 'g', CURRENT_DATE + 365),
  ('00000000-0000-0000-0000-000000000001', 'Sugar',             '', '', 'generic', 'condiments', '1 kg',  ARRAY[0.6],  'g', CURRENT_DATE + 300),
  ('00000000-0000-0000-0000-000000000001', 'Black Pepper',      '', '', 'generic', 'condiments', '100 g', ARRAY[0.6],  '%', CURRENT_DATE + 240),
  ('00000000-0000-0000-0000-000000000001', 'Paprika',           '', '', 'generic', 'condiments', '50 g',  ARRAY[0.45], '%', CURRENT_DATE + 200),
  ('00000000-0000-0000-0000-000000000001', 'Cumin',             '', '', 'generic', 'condiments', '50 g',  ARRAY[0.7],  '%', CURRENT_DATE + 220),
  ('00000000-0000-0000-0000-000000000001', 'Turmeric',          '', '', 'generic', 'condiments', '50 g',  ARRAY[0.55], '%', CURRENT_DATE + 210),
  ('00000000-0000-0000-0000-000000000001', 'Chilli Flakes',     '', '', 'generic', 'condiments', '40 g',  ARRAY[0.3],  '%', CURRENT_DATE + 180),
  ('00000000-0000-0000-0000-000000000001', 'Oregano',           '', '', 'generic', 'condiments', '30 g',  ARRAY[0.5],  '%', CURRENT_DATE + 160),
  ('00000000-0000-0000-0000-000000000001', 'Bay Leaves',        '', '', 'generic', 'condiments', '20 g',  ARRAY[0.8],  '%', CURRENT_DATE + 300),
  ('00000000-0000-0000-0000-000000000001', 'Garam Masala',      '', '', 'generic', 'condiments', '50 g',  ARRAY[0.25], '%', CURRENT_DATE + 190),
  ('00000000-0000-0000-0000-000000000001', 'Coriander Powder',  '', '', 'generic', 'condiments', '50 g',  ARRAY[0.65], '%', CURRENT_DATE + 230),
  ('00000000-0000-0000-0000-000000000001', 'Nutmeg',            '', '', 'generic', 'condiments', '30 g',  ARRAY[0.7],  '%', CURRENT_DATE + 280),

  -- Frozen & Canned
  ('00000000-0000-0000-0000-000000000001', 'Canned Chickpeas', 'Goya', 'prod-chickpeas', 'product', 'frozen', '400 g can', ARRAY[1.0], '%', CURRENT_DATE + 240);
