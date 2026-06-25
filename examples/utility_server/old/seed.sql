INSERT INTO end_device (id, lfdi, sfdi, device_type, pin, enabled, registration_state, changed_time, created_time, post_rate) VALUES
    ('1pr4mxxk8ums7f', 'b80cbcc76028a74f5108a60382dd8a963e85c655', '32030', 'aggregator', -28.084045, NULL, 'rejected', -885.83325, -956.3569, 529.38116),
    ('rr3egsp3w19ofv', '03d23b11c4cb111a6e6bac9df480804a3da09c1f', '08203', 'direct_der', -87.59235, TRUE, 'pending', -370.53156, -718.74554, 337.79974),
    ('t1y3tfvodtdij', '237ffaa36bff6295e6cf6c8286e9814f39cc3fb4', '43838', 'direct_der', 61.455933, NULL, 'inactive', -359.65344, -942.173, 782.34814),
    ('sk9ppm2fa0j9yf9jhqte', 'fe317957c46f6b11816cacd2d1deabdba46206c7', '40254', 'direct_der', 267.85107, NULL, 'rejected', 193.89087, -341.13513, 828.7738),
    ('o54', 'd1846afbb4135c2a34fbc6911d2d691724087ec9', '66571', 'aggregator', 276.073, TRUE, 'rejected', 913.95215, 803.4352, 468.72455),
    ('ly1okqm2w', '191670e5bb80a8ddff84e1fc0c193c86677027af', '53462', 'direct_der', -820.40405, NULL, 'deleted', -386.03784, -491.07324, 271.60086);

INSERT INTO connection_point (id, nmi, connection_status, end_device_id) VALUES
    ('3mns5p6bic', 'j0', 'disconnected', NULL),
    ('kg', 'jbi7ontb0k0', 'disconnected', NULL),
    ('lb5i3jgsw0l', 'hssnvzqjwenzzhe', 'disconnected', NULL),
    ('y2', 'ynypyn', 'connected', NULL),
    ('4aydzq', 'fvteq2', 'connected', NULL),
    ('lh4', '6if', 'disconnected', NULL),
    ('ypbceyke5o9ss5ol', 'v2xx88ctgcezy', 'connected', NULL),
    ('ocar2uzp', 'z6d0ezokl907crq', 'connected', NULL);

INSERT INTO device_capability (id, poll_rate, end_device_list_link, mirror_usage_point_list_link, time_link, der_program_list_link, self_device_link) VALUES
    ('device_capability-1', 550.73914, TRUE, NULL, NULL, NULL, NULL),
    ('device_capability-2', 801.8653, TRUE, NULL, NULL, TRUE, NULL),
    ('device_capability-3', 591.11945, TRUE, NULL, TRUE, TRUE, TRUE),
    ('device_capability-4', 896.83386, TRUE, NULL, NULL, TRUE, NULL),
    ('device_capability-5', 495.82724, TRUE, NULL, NULL, NULL, NULL),
    ('device_capability-6', 773.6174, TRUE, NULL, TRUE, NULL, TRUE),
    ('device_capability-7', 946.8052, TRUE, NULL, NULL, NULL, TRUE),
    ('device_capability-8', 278.05988, TRUE, TRUE, NULL, TRUE, NULL),
    ('device_capability-9', 652.32965, TRUE, TRUE, NULL, NULL, NULL),
    ('device_capability-10', 931.28784, TRUE, TRUE, NULL, TRUE, TRUE),
    ('device_capability-11', 815.15686, TRUE, TRUE, TRUE, TRUE, NULL),
    ('device_capability-12', 146.14311, TRUE, NULL, NULL, TRUE, TRUE),
    ('device_capability-13', 569.5128, TRUE, NULL, NULL, TRUE, TRUE),
    ('device_capability-14', 498.01068, TRUE, NULL, NULL, NULL, NULL),
    ('device_capability-15', 234.08812, TRUE, TRUE, TRUE, TRUE, NULL),
    ('device_capability-16', 897.6955, TRUE, TRUE, NULL, TRUE, TRUE),
    ('device_capability-17', 650.1559, TRUE, NULL, NULL, NULL, NULL),
    ('device_capability-18', 189.88013, TRUE, TRUE, TRUE, NULL, TRUE),
    ('device_capability-19', 528.39197, TRUE, NULL, TRUE, NULL, TRUE),
    ('device_capability-20', 184.71777, TRUE, TRUE, NULL, NULL, TRUE);

INSERT INTO mirror_usage_point (id, mrid, description, role_flags, status, created_time, changed_time, last_update_time, timeout_seconds, end_device_id) VALUES
    ('jr2i98z', '0s', 'tknq00ly', 370.14783, 'inactive', 1000000188, 1000000198, 353.93262, 271.18686, NULL),
    ('gxy40oy2m', '08', 'avbu69pspeug', 996.1698, 'inactive', 1000000820, 1000001035, -407.22943, 129.15854, NULL),
    ('g3irj9ubmyc1l8fv', 'v4s767fkia4w5aex', 'mh', 871.76404, 'expired', 1000000217, 1000000616, 588.0254, 445.89456, NULL),
    ('xyt41apx', '1tvl', '1e49jmal', 291.58365, 'inactive', 1000000725, 1000000951, 960.4437, 37.208565, NULL),
    ('jrynqy0p1p059bzia31', 'wsyb32', 'b41q55x9k', 34.68609, 'expired', 1000000857, 1000001292, -532.0308, 900.758, NULL),
    ('2e4t7tp91ur', 'f', '1rz', 879.38904, 'inactive', 1000000896, 1000001275, 922.0569, 435.40393, NULL),
    ('1zogc0', 'hl', '6eck1ou', 252.83075, 'inactive', 1000000073, 1000000190, 594.1034, 155.93924, NULL);

INSERT INTO mirror_meter_reading (id, mrid, description, reading_type, value, time_stamp, quality, created_time, mirror_usage_point_id) VALUES
    ('aaal3', 's03dj9wlila2zv', 'izv6mjs', 'clzqw', 878.2134, 1000008486, 'questionable', 1000008535, NULL),
    ('501omi1u', 'nown4smpaasto9nvb3', 'rggzgx172e0l', 'e3b', -701.2854, 1000004246, 'estimated', 1000004344, NULL),
    ('xxk1o', 'k38x3txnikmpu32l6ve', 'w5tuzdmcp3cz', 'zzvga5c7zxf', 645.97156, 1000007542, 'estimated', 1000007632, NULL),
    ('hpesxymyo4cu9q', 'qaj5e3hkftp1kjb', 'w4iwtkxao0dd', 'oi3e1r', -53.221252, 1000003563, 'questionable', 1000003598, NULL),
    ('zv3weel4pgr16eq', 'y1xnkeqvggc4x', '6gagee81ucctxq', 'ey', 529.1062, 1000005713, 'questionable', 1000005781, NULL),
    ('knf8wjfttw3t', 'ov34mtyn', 'hedua1dl8', '4vgpo', 999.53345, 1000008381, 'valid', 1000008383, NULL),
    ('mdu1d261xo1qy', '7fgswvuoc', 'bsz2ww0rf9a4m', 'ti7x43dasur0r6gaat', 277.10034, 1000001160, 'questionable', 1000001250, NULL),
    ('v8sn7gkzmeeobcxv3', '373ads', '94ojl', '6tf4okn3', -630.0125, 1000004481, 'estimated', 1000004503, NULL),
    ('46ao1l9q0q', '9us4jqyp1zvx0m', 'e2n0ydc3', 'u7yfemao9ygyud', -309.06512, 1000009227, 'questionable', 1000009241, NULL),
    ('qvds9ke', 'he1obnzb386mei', 'qpqletch56sybq7o', 'lqbirldyf2', 137.32239, 1000009112, 'missing', 1000009166, NULL),
    ('awhof8z6ckuvpp', 'u', 'nwsfrvhw21fh9dn', '6lww5gu', -870.9219, 1000004189, 'questionable', 1000004242, NULL),
    ('9', 'ywxolsq4gs', 'x0c9ynu7pi0bq9v9sz', '461kgwoakwiu36xco2i', -547.06433, 1000006874, 'estimated', 1000006935, NULL),
    ('zbkvyj3pi931kvb8a8', '04x1ijw6kzwpb', '55yqejfhi2cgg8y10', '9t', -882.68066, 1000004931, 'questionable', 1000005017, NULL),
    ('ixr', 'x03', '6pvagc83o', 'g2zmt1z10pf6wdp7r', 640.80334, 1000009962, 'estimated', 1000010006, NULL),
    ('5h3r', '26', '1nwbkwrvuf', '0xiavwa946y0vgom', 332.2494, 1000003379, 'questionable', 1000003461, NULL),
    ('y7', 'bxmxqn', '2es5', 'oxfmesfryqu0', -965.27435, 1000002182, 'questionable', 1000002280, NULL);

INSERT INTO time_resource (id, current_time, quality, local_offset, dst_offset, dst_start, dst_end) VALUES
    ('time_resource-21', 178.05779, 'level_3', -759.5062, 603.12646, -585.20197, -526.0036),
    ('time_resource-22', 954.4595, 'inaccurate', -447.74152, -793.5674, 64.750854, 613.50757),
    ('time_resource-23', 868.2717, 'authoritative', -950.9649, -547.6866, 449.08472, -197.84381),
    ('time_resource-24', 534.0062, 'authoritative', 949.3683, -738.63196, -872.46106, 122.89172),
    ('time_resource-25', 973.7642, 'level_5', -571.2714, 291.6012, 14.812012, 844.95325),
    ('time_resource-26', 811.6526, 'inaccurate', 911.3374, -581.94495, -392.9651, 416.5127),
    ('time_resource-27', 172.86385, 'level_4', -936.3985, 483.65234, -171.64874, 683.1787),
    ('time_resource-28', 188.30501, 'level_6', 75.374146, 537.2837, -979.11835, -541.73303),
    ('time_resource-29', 863.18195, 'level_3', -109.46704, -763.4041, -828.743, 429.04858),
    ('time_resource-30', 108.71178, 'level_3', 543.8325, -239.57727, -341.542, -74.3656),
    ('time_resource-31', 246.95985, 'authoritative', -428.1914, 679.5792, 964.43823, -476.73322),
    ('time_resource-32', 933.04285, 'inaccurate', -562.88477, 429.8141, -378.8507, 555.9487),
    ('time_resource-33', 41.60536, 'inaccurate', -654.19653, -170.96088, -92.906494, -550.53735),
    ('time_resource-34', 871.757, 'inaccurate', 67.822266, -838.5685, 12.688171, 982.44434),
    ('time_resource-35', 557.29315, 'authoritative', 11.578308, 96.1676, -968.5278, -552.43945),
    ('time_resource-36', 5.0145802, 'level_6', 645.4435, 248.76208, -32.954956, 801.5034),
    ('time_resource-37', 827.7965, 'level_6', -153.19635, -167.35553, -597.9397, 642.8838),
    ('time_resource-38', 940.5581, 'level_5', 957.70593, -62.352417, -851.5651, -180.20654),
    ('time_resource-39', 323.27386, 'inaccurate', 431.54553, -920.79114, 78.36914, 614.9397),
    ('time_resource-40', 489.20984, 'level_5', 176.40637, -168.49158, 503.7644, 811.77954);

INSERT INTO acl_entry (id, target_lfdi, resource_path, method, auth_type, device_type_filter, allowed) VALUES
    ('x1mu7o2s2lyy6', 'fe317957c46f6b11816cacd2d1deabdba46206c7', 'nmaz971ia2kw5nlit', 'delete', 'pin', 'aggregator', TRUE),
    ('gdjylxx7ueaa9i66', 'fe317957c46f6b11816cacd2d1deabdba46206c7', 'x', 'post', 'pin', 'any', TRUE),
    ('ex002', 'fe317957c46f6b11816cacd2d1deabdba46206c7', 'w2zb3l9j', 'delete', 'certificate', 'direct_der', NULL),
    ('l9r3w4hmrn21y7lslju', 'fe317957c46f6b11816cacd2d1deabdba46206c7', 'xgcquijrrqopx5qt91', 'put', 'certificate', 'direct_der', TRUE),
    ('d54bo7bp6cf', 'd1846afbb4135c2a34fbc6911d2d691724087ec9', 'suyyeqx', 'head', 'pin', 'aggregator', TRUE),
    ('0a3mp0t1o7spx2ml', 'd1846afbb4135c2a34fbc6911d2d691724087ec9', 'iilwww', 'put', 'none', 'any', NULL),
    ('cv', 'd1846afbb4135c2a34fbc6911d2d691724087ec9', 'eticghggjy', 'put', 'pin', 'direct_der', NULL),
    ('593wjtm', 'd1846afbb4135c2a34fbc6911d2d691724087ec9', 'jeyt7nlm', 'delete', 'certificate', 'aggregator', NULL),
    ('yk7c5vcqccl6q8', 'd1846afbb4135c2a34fbc6911d2d691724087ec9', 'hjdldyt6j6xt4vh2o', 'put', 'pin', 'any', NULL),
    ('m9uanqo', '191670e5bb80a8ddff84e1fc0c193c86677027af', 'z8qxk7', 'head', 'pin', 'direct_der', TRUE);

