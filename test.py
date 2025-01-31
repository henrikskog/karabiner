import random

random_number = random.randint(1, 100)
print(f"Random number: {random_number}")

# Write the number to a temporary file so we can use it in the README
with open('random_number.txt', 'w') as f:
    f.write(str(random_number)) 