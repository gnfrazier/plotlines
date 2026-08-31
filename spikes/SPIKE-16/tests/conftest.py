import os
import sys

# Spike modules import each other by bare name, matching the other spikes.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
