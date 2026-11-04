import json
A = [-2664, -862]
B = [-2024, -862]   # 相距 640m(一个区块格)
shots = []
for i in range(24):
    p = A if i % 2 == 0 else B
    shots.append({"name": "ping_%02d" % i,
                  "env": {"light_mode": 0, "tier": "medium",
                          "goto": [p[0], p[1], 90], "diag": True}})
json.dump({"warmup": 8.0, "gap": 2.0, "settle": 1.2, "shots": shots},
          open("tools/shot_plan_line.json", "w"), indent=1)
print("ping-pong hops:", len(shots))
